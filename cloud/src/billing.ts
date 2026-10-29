import { DurableObject } from 'cloudflare:workers';
import type { Env, Identity, TeamRow } from './types';
import { authenticate, getTeam, premium, requireTeam } from './access';
import { APIError, assert, bytes, escapeHTML, failure, id, json, publicBase, rateLimit, str, uuid } from './http';
import { refreshTeamAccess } from './notifications';

type StripeObject = Record<string, any>;
interface BillingRPC { reconcile(teamId:string,eventId?:string,eventType?:string,eventCreated?:number):Promise<{status:string}> }
const STRIPE_VERSION = '2025-04-30.basil';

export async function stripe(env:Env,path:string,method='GET',values?:Record<string,string>,key?:string):Promise<StripeObject> {
  assert(env.STRIPE_SECRET_KEY,503,'billing_not_configured','Team billing is not configured on this server.');
  const headers:Record<string,string>={Authorization:`Bearer ${env.STRIPE_SECRET_KEY}`,'Stripe-Version':STRIPE_VERSION};
  if(key)headers['Idempotency-Key']=key;
  if(values)headers['Content-Type']='application/x-www-form-urlencoded';
  const response=await fetch(`https://api.stripe.com/v1${path}`,{method,headers,body:values?new URLSearchParams(values):undefined,signal:AbortSignal.timeout(20000)});
  assert(response.ok,502,'billing_provider_error','The billing provider could not complete this request. Please retry.');
  return await response.json<StripeObject>();
}
function subscriptionEnd(subscription:StripeObject):number {
  const ends=[subscription.current_period_end,subscription.trial_end,...(subscription.items?.data??[]).map((i:StripeObject)=>i.current_period_end)].filter((n:unknown)=>typeof n==='number'&&Number.isSafeInteger(n));
  return Math.max(0,...ends)*1000;
}
function matching(subscription:StripeObject,teamId:string,customer:string,price:string):boolean {
  return subscription.customer===customer&&subscription.metadata?.teamId===teamId&&subscription.items?.data?.length===1&&subscription.items.data[0].price?.id===price&&subscription.items.data[0].quantity===1;
}

/** All billing changes for one team use one serial coordinator, preventing an old
 * cancellation event from racing a new checkout and revoking a new subscription. */
export class BillingCoordinator extends DurableObject<Env> {
  private queue:Promise<unknown>=Promise.resolve();
  private serialized<T>(work:()=>Promise<T>):Promise<T>{const next=this.queue.catch(()=>{}).then(work);this.queue=next.catch(()=>{});return next;}
  async reconcile(teamId:string,eventId?:string,eventType='scheduled',eventCreated=Date.now()):Promise<{status:string}>{
    return this.serialized(async()=>{
      id(teamId);
      if(eventId){const done=await this.env.DB.prepare('SELECT id FROM billing_events WHERE id=?').bind(eventId).first();if(done)return{status:'already_processed'};}
      const team=await getTeam(this.env,teamId);
      if(!team.stripe_customer_id)return{status:'no_customer'};
      assert(this.env.STRIPE_TEAM_PRICE_ID,503,'billing_not_configured','Team price is not configured.');
      const subscriptions:StripeObject[]=[];let cursor:string|undefined;
      for(let page=0;page<10;page++){
        const query=new URLSearchParams({customer:team.stripe_customer_id,status:'all',limit:'100'});if(cursor)query.set('starting_after',cursor);
        const result=await stripe(this.env,`/subscriptions?${query}`);subscriptions.push(...(result.data??[]));
        if(!result.has_more)break;
        cursor=result.data?.at(-1)?.id;assert(cursor&&page<9,502,'billing_provider_error','Subscription history could not be completely checked.');
      }
      const candidates=subscriptions.filter(s=>matching(s,teamId,team.stripe_customer_id!,this.env.STRIPE_TEAM_PRICE_ID!));
      const active=candidates.filter(s=>['active','trialing'].includes(s.status)&&subscriptionEnd(s)>Date.now()).sort((a,b)=>Number(b.created)-Number(a.created));
      const selected=active[0]??candidates.find(s=>s.id===team.subscription_id)??candidates.sort((a,b)=>Number(b.created)-Number(a.created))[0];
      const status=selected?.status??'free',end=selected?subscriptionEnd(selected):team.current_period_end??0,now=Date.now();
      const canceled=['active','trialing'].includes(status)?null:team.canceled_at??now;
      const statements=[this.env.DB.prepare('UPDATE teams SET subscription_id=?,subscription_status=?,current_period_end=?,paid_until=?,canceled_at=?,billing_checked_at=? WHERE id=?').bind(selected?.id??null,status,end,end,canceled,now,teamId)];
      if(eventId)statements.push(this.env.DB.prepare('INSERT INTO billing_events(id,team_id,event_type,created_at,processed_at) VALUES(?,?,?,?,?)').bind(eventId,teamId,eventType,eventCreated,now));
      await this.env.DB.batch(statements);
      await refreshTeamAccess(this.env,teamId);
      return{status};
    });
  }
  async fetch(request:Request):Promise<Response>{
    try{return await this.serialized(async()=>{
      const match=/^\/v1\/teams\/([^/]+)\/billing\/(checkout|portal)$/.exec(new URL(request.url).pathname);assert(match&&request.method==='POST',404,'not_found','Billing route not found.');
      const identity=await authenticate(request,this.env),teamId=id(match[1]);const {team}=await requireTeam(this.env,teamId,identity.user.id,['owner']);
      assert(this.env.STRIPE_TEAM_PRICE_ID,503,'billing_not_configured','Team billing is not configured on this server.');
      let customer=team.stripe_customer_id;
      if(!customer){
        const created=await stripe(this.env,'/customers','POST',{'name':team.name,...(identity.user.email?{'email':identity.user.email}:{}),'metadata[teamId]':teamId},`scriv-customer-${teamId}`);
        customer=str(created.id,'customer',100);await this.env.DB.prepare('UPDATE teams SET stripe_customer_id=? WHERE id=? AND stripe_customer_id IS NULL').bind(customer,teamId).run();
      }
      const base=publicBase(this.env);
      if(match[2]==='portal'){
        const session=await stripe(this.env,'/billing_portal/sessions','POST',{customer,return_url:`${base}/billing/return?team=${encodeURIComponent(teamId)}`});return json({url:session.url});
      }
      assert(!premium(team),409,'already_subscribed','This team already has an active subscription. Manage it in the billing portal.');
      const price=await stripe(this.env,`/prices/${encodeURIComponent(this.env.STRIPE_TEAM_PRICE_ID)}`);
      assert(price.active&&price.currency==='usd'&&price.unit_amount===999&&price.recurring?.interval==='month'&&price.recurring?.interval_count===1,503,'invalid_team_price','Configure one recurring USD $9.99 monthly Team price.');
      const cached=await this.ctx.storage.get<{id:string;expiresAt:number}>(`checkout:${teamId}`);
      if(cached&&cached.expiresAt>Date.now()){
        const old=await stripe(this.env,`/checkout/sessions/${encodeURIComponent(cached.id)}`);
        if(old.status==='open'&&old.url)return json({url:old.url});
        assert(old.status!=='complete',409,'billing_processing','Payment is processing. Refresh your account shortly.');
      }
      const requestKey=(await this.ctx.storage.get<string>(`checkout-attempt:${teamId}`))??uuid();await this.ctx.storage.put(`checkout-attempt:${teamId}`,requestKey);
      const checkout=await stripe(this.env,'/checkout/sessions','POST',{
        mode:'subscription',customer,client_reference_id:teamId,'metadata[teamId]':teamId,'subscription_data[metadata][teamId]':teamId,
        'line_items[0][price]':this.env.STRIPE_TEAM_PRICE_ID,'line_items[0][quantity]':'1',allow_promotion_codes:'false',
        success_url:`${base}/billing/return?team=${encodeURIComponent(teamId)}`,cancel_url:`${base}/billing/return?team=${encodeURIComponent(teamId)}&canceled=1`
      },`scriv-checkout-${teamId}-${requestKey}`);
      assert(typeof checkout.url==='string'&&checkout.url.startsWith('https://checkout.stripe.com/'),502,'billing_provider_error','The checkout URL was invalid.');
      await this.ctx.storage.put(`checkout:${teamId}`,{id:checkout.id,expiresAt:Number(checkout.expires_at)*1000});await this.ctx.storage.delete(`checkout-attempt:${teamId}`);
      return json({url:checkout.url});
    });}catch(error){return failure(error);}
  }
}

export async function verifyStripeSignature(raw:string,signature:string,secret:string,now=Date.now()):Promise<boolean>{
  const fields=signature.split(',').map(v=>v.split('='));const timestamp=fields.find(([key])=>key==='t')?.[1];
  if(!timestamp||!/^\d+$/.test(timestamp)||Math.abs(now/1000-Number(timestamp))>300)return false;
  const signatures=fields.filter(([key])=>key==='v1').map(([,value])=>value).filter((s):s is string=>!!s&&/^[a-f0-9]{64}$/.test(s));
  if(!signatures.length)return false;
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  const data=new TextEncoder().encode(`${timestamp}.${raw}`);
  for(const value of signatures){const bytes=new Uint8Array(value.match(/../g)!.map(hex=>parseInt(hex,16)));if(await crypto.subtle.verify('HMAC',key,bytes,data))return true;}
  return false;
}
export async function webhook(request:Request,env:Env):Promise<Response>{
  assert(env.STRIPE_WEBHOOK_SECRET,503,'billing_not_configured','Billing webhook is not configured.');
  const raw=new TextDecoder().decode(await bytes(request,262144));assert(await verifyStripeSignature(raw,request.headers.get('stripe-signature')??'',env.STRIPE_WEBHOOK_SECRET),400,'invalid_signature','Invalid Stripe signature.');
  let event:StripeObject;try{event=JSON.parse(raw);}catch{throw new APIError(400,'invalid_json','Invalid webhook body.');}
  const eventId=str(event.id,'event.id',128),type=str(event.type,'event.type',128);
  const accepted=['checkout.session.completed','checkout.session.async_payment_succeeded','customer.subscription.created','customer.subscription.updated','customer.subscription.deleted','invoice.paid','invoice.payment_failed'];
  if(!accepted.includes(type))return json({received:true,ignored:true});
  const object=event.data?.object;assert(object&&typeof object==='object',400,'invalid_event','Webhook object is missing.');
  const customer=typeof object.customer==='string'?object.customer:object.customer?.id;
  assert(typeof customer==='string',400,'invalid_customer','Webhook customer is missing.');
  const team=await env.DB.prepare('SELECT id FROM teams WHERE stripe_customer_id=?').bind(customer).first<{id:string}>();
  if(!team)return json({received:true,ignored:true});
  const rpc=env.BILLING.get(env.BILLING.idFromName(team.id)) as unknown as BillingRPC;
  await rpc.reconcile(team.id,eventId,type,Number(event.created)*1000||Date.now());
  return json({received:true});
}
export async function billingRoutes(request:Request,env:Env,identity:Identity):Promise<Response|null>{
  const match=/^\/v1\/teams\/([^/]+)\/billing\/(checkout|portal)$/.exec(new URL(request.url).pathname);if(!match)return null;
  const teamId=id(match[1]);await requireTeam(env,teamId,identity.user.id,['owner']);await rateLimit(env,`billing:${identity.user.id}`,30,3600000);
  return env.BILLING.get(env.BILLING.idFromName(teamId)).fetch(request);
}
export function billingReturn(request:Request):Response{
  const team=new URL(request.url).searchParams.get('team')??'';const href=`scriv://billing/${encodeURIComponent(team)}`;
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Scriv billing</title><style>body{font:17px system-ui;max-width:32rem;margin:12vh auto;padding:2rem;background:#f5f7fc;color:#17213b}a{color:#1769ff}</style><h1>Return to your story.</h1><p>Scriv will update your team when the billing provider confirms your subscription.</p><a href="${escapeHTML(href)}">Open Scriv</a></html>`,{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store','content-security-policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"}});
}
export async function reconcileBilling(env:Env):Promise<void>{
  const teams=await env.DB.prepare('SELECT id FROM teams WHERE stripe_customer_id IS NOT NULL AND (billing_checked_at IS NULL OR billing_checked_at<?) ORDER BY COALESCE(billing_checked_at,0) LIMIT 100').bind(Date.now()-6*3600000).all<{id:string}>();
  for(let i=0;i<teams.results.length;i+=5)await Promise.allSettled(teams.results.slice(i,i+5).map(team=>(env.BILLING.get(env.BILLING.idFromName(team.id)) as unknown as BillingRPC).reconcile(team.id)));
}
