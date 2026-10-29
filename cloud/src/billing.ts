import { DurableObject } from 'cloudflare:workers';
import type { Env, Identity } from './types';
import { authenticate, getTeam, premium, requireTeam } from './access';
import { APIError, assert, bytes, escapeHTML, failure, id, json, publicBase, rateLimit, record, str, uuid } from './http';
import { refreshTeamAccess } from './notifications';

type StripeObject = Record<string, any>;
interface BillingResult { status:string; retry?:boolean }
interface BillingRPC { reconcile(teamId:string,eventId?:string,eventType?:string,eventCreated?:number):Promise<BillingResult> }
const STRIPE_VERSION = '2025-04-30.basil';
const TERMINAL_SUBSCRIPTIONS = new Set(['canceled','incomplete_expired']);
interface Reconciliation { status:string; subscriptions:StripeObject[] }

export async function stripe(env:Env,path:string,method='GET',values?:Record<string,string>,key?:string):Promise<StripeObject> {
  assert(env.STRIPE_SECRET_KEY,503,'billing_not_configured','Team billing is not configured on this server.');
  const headers:Record<string,string>={Authorization:`Bearer ${env.STRIPE_SECRET_KEY}`,'Stripe-Version':STRIPE_VERSION};
  if(key)headers['Idempotency-Key']=key;
  if(values)headers['Content-Type']='application/x-www-form-urlencoded';
  let response:Response;
  try{response=await fetch(`https://api.stripe.com/v1${path}`,{method,headers,body:values?new URLSearchParams(values):undefined,signal:AbortSignal.timeout(20000)});}
  catch{throw new APIError(502,'billing_provider_error','The billing provider could not be reached. Please retry.');}
  assert(response.ok,502,'billing_provider_error','The billing provider could not complete this request. Please retry.');
  let result:unknown;
  try { result=await response.json(); } catch { throw new APIError(502,'billing_provider_error','The billing provider returned an invalid response.'); }
  assert(result!==null&&typeof result==='object'&&!Array.isArray(result),502,'billing_provider_error','The billing provider returned an invalid response.');
  return result as StripeObject;
}
function subscriptionEnd(subscription:StripeObject):number {
  // Basil moved the billing period to the subscription item. A historical trial
  // must not extend the entitlement beyond the current item's actual period.
  const end=subscription.items?.data?.[0]?.current_period_end??subscription.current_period_end??(subscription.status==='trialing'?subscription.trial_end:0);
  return timestamp(end);
}
function timestamp(value:unknown):number { return typeof value==='number'&&Number.isSafeInteger(value)&&value>0&&value<=Number.MAX_SAFE_INTEGER/1000?value*1000:0; }
function stripeId(value:unknown):string|undefined { return typeof value==='string'?value:value!==null&&typeof value==='object'&&'id' in value&&typeof value.id==='string'?value.id:undefined; }
function providerURL(value:unknown,host:string):string {
  let url:URL|undefined;try{if(typeof value==='string')url=new URL(value);}catch{}
  assert(url&&url.protocol==='https:'&&url.hostname===host&&!url.username&&!url.password&&!url.port,502,'billing_provider_error','The billing provider returned an invalid URL.');
  return url.href;
}
function validPrice(price:StripeObject):boolean {
  return price.active===true&&price.currency==='usd'&&price.unit_amount===999&&price.type==='recurring'&&price.billing_scheme==='per_unit'&&price.recurring?.interval==='month'&&price.recurring?.interval_count===1&&price.recurring?.usage_type==='licensed'&&!price.transform_quantity&&!price.custom_unit_amount;
}
function matching(subscription:StripeObject,teamId:string,customer:string,price:string):boolean {
  return stripeId(subscription.customer)===customer&&subscription.metadata?.teamId===teamId&&subscription.items?.data?.length===1&&!subscription.items.has_more&&subscription.items.data[0].price?.id===price&&subscription.items.data[0].quantity===1;
}

/** All billing changes for one team use one serial coordinator, preventing an old
 * cancellation event from racing a new checkout and revoking a new subscription. */
export class BillingCoordinator extends DurableObject<Env> {
  private queue:Promise<unknown>=Promise.resolve();
  private serialized<T>(work:()=>Promise<T>):Promise<T>{const next=this.queue.catch(()=>{}).then(work);this.queue=next.catch(()=>{});return next;}
  async reconcile(teamId:string,eventId?:string,eventType='scheduled',eventCreated=Date.now()):Promise<BillingResult>{
    try{return await this.serialized(async()=>{
      id(teamId);
      if(eventId){
        const done=await this.env.DB.prepare('SELECT team_id FROM billing_events WHERE id=?').bind(eventId).first<{team_id:string}>();
        if(done){
          assert(done.team_id===teamId,409,'event_reused','This billing event has already been processed for another team.');
          // D1 may have committed before a room refresh failed. Replays retry
          // that propagation without reapplying an obsolete provider snapshot.
          await refreshTeamAccess(this.env,teamId);
          return{status:'already_processed'};
        }
      }
      const result=await this.synchronize(teamId,eventId,eventType,eventCreated);
      return{status:result.status};
    });}catch(error){
      // Expected provider outages travel as data, not custom Error subclasses:
      // RPC strips those prototypes and would log them as uncaught exceptions.
      console.warn('Scriv billing reconciliation retry required',error instanceof APIError?error.code:'internal_error');
      return{status:'retry_required',retry:true};
    }
  }
  private async synchronize(teamId:string,eventId?:string,eventType='checkout',eventCreated=Date.now()):Promise<Reconciliation>{
      const team=await getTeam(this.env,teamId);
      if(!team.stripe_customer_id)return{status:'no_customer',subscriptions:[]};
      assert(this.env.STRIPE_TEAM_PRICE_ID,503,'billing_not_configured','Team price is not configured.');
      const subscriptions:StripeObject[]=[];let cursor:string|undefined;
      for(let page=0;page<10;page++){
        const query=new URLSearchParams({customer:team.stripe_customer_id,status:'all',limit:'100'});if(cursor)query.set('starting_after',cursor);
        const result=await stripe(this.env,`/subscriptions?${query}`);
        assert(Array.isArray(result.data)&&typeof result.has_more==='boolean'&&result.data.every((s:unknown)=>s!==null&&typeof s==='object'&&!Array.isArray(s)&&typeof (s as StripeObject).id==='string'&&typeof (s as StripeObject).status==='string'&&stripeId((s as StripeObject).customer)===team.stripe_customer_id),502,'billing_provider_error','Subscription history could not be verified.');
        subscriptions.push(...result.data);
        if(!result.has_more)break;
        const next=result.data.at(-1)?.id;assert(next&&next!==cursor&&page<9,502,'billing_provider_error','Subscription history could not be completely checked.');cursor=next;
      }
      const candidates=subscriptions.filter(s=>matching(s,teamId,team.stripe_customer_id!,this.env.STRIPE_TEAM_PRICE_ID!));
      const active=candidates.filter(s=>['active','trialing'].includes(s.status)&&subscriptionEnd(s)>Date.now()).sort((a,b)=>Number(b.created)-Number(a.created));
      const selected=active[0]??candidates.find(s=>s.id===team.subscription_id)??candidates.sort((a,b)=>Number(b.created)-Number(a.created))[0];
      const status=selected?.status??'free',end=selected?subscriptionEnd(selected):team.current_period_end??0,now=Date.now();
      const entitled=['active','trialing'].includes(status)&&end>now;
      // A delayed cancellation delivery must not restart the 30-day read grace.
      const ended=timestamp(selected?.ended_at);
      const canceled=entitled?null:team.canceled_at??Math.min(now,ended||end||now);
      const statements=[this.env.DB.prepare('UPDATE teams SET subscription_id=?,subscription_status=?,current_period_end=?,paid_until=?,canceled_at=?,billing_checked_at=? WHERE id=?').bind(selected?.id??null,status,end,end,canceled,now,teamId)];
      if(eventId)statements.push(this.env.DB.prepare('INSERT INTO billing_events(id,team_id,event_type,created_at,processed_at) VALUES(?,?,?,?,?)').bind(eventId,teamId,eventType,eventCreated,now));
      await this.env.DB.batch(statements);
      await refreshTeamAccess(this.env,teamId);
      return{status,subscriptions};
  }
  async fetch(request:Request):Promise<Response>{
    try{return await this.serialized(async()=>{
      const match=/^\/v1\/teams\/([^/]+)\/billing\/(checkout|portal)$/.exec(new URL(request.url).pathname);assert(match&&request.method==='POST',404,'not_found','Billing route not found.');
      const identity=await authenticate(request,this.env),teamId=id(match[1]);const {team}=await requireTeam(this.env,teamId,identity.user.id,['owner']);
      const confirmOwner=async()=>{const current=await authenticate(request,this.env);await requireTeam(this.env,teamId,current.user.id,['owner']);};
      assert(this.env.STRIPE_SECRET_KEY,503,'billing_not_configured','Team billing is not configured on this server.');
      const base=publicBase(this.env);
      if(match[2]==='portal'){
        assert(team.stripe_customer_id,409,'billing_customer_required','Start a Team subscription before opening the billing portal.');
        const session=await stripe(this.env,'/billing_portal/sessions','POST',{customer:team.stripe_customer_id,return_url:`${base}/billing/return?team=${encodeURIComponent(teamId)}`});
        await confirmOwner();
        return json({url:providerURL(session.url,'billing.stripe.com')});
      }
      assert(this.env.STRIPE_TEAM_PRICE_ID,503,'billing_not_configured','Team billing is not configured on this server.');
      // Verify the fixed, licensed Team price before creating any provider state.
      const price=await stripe(this.env,`/prices/${encodeURIComponent(this.env.STRIPE_TEAM_PRICE_ID)}`);
      assert(price.id===this.env.STRIPE_TEAM_PRICE_ID&&validPrice(price),503,'invalid_team_price','Configure one fixed, licensed USD $9.99 monthly Team price.');
      await confirmOwner();
      let customer=team.stripe_customer_id;
      if(!customer){
        const created=await stripe(this.env,'/customers','POST',{'name':team.name,...(identity.user.email?{'email':identity.user.email}:{}),'metadata[teamId]':teamId},`scriv-customer-${teamId}`);
        customer=str(created.id,'customer',100);await this.env.DB.prepare('UPDATE teams SET stripe_customer_id=? WHERE id=? AND stripe_customer_id IS NULL').bind(customer,teamId).run();
      }
      // Never rely on webhook timing or a local expiry before offering another
      // charge. A completed checkout may outlive expires_at and a missed webhook.
      const current=await this.synchronize(teamId);
      await confirmOwner();
      assert(!premium(await getTeam(this.env,teamId)),409,'already_subscribed','This team already has an active subscription. Manage it in the billing portal.');
      assert(!current.subscriptions.some(s=>!TERMINAL_SUBSCRIPTIONS.has(s.status)),409,'subscription_exists','This team already has a pending or inactive subscription. Manage it in the billing portal instead of starting another.');
      const cached=await this.ctx.storage.get<{id:string;expiresAt:number}>(`checkout:${teamId}`);
      if(cached){
        const old=await stripe(this.env,`/checkout/sessions/${encodeURIComponent(cached.id)}`);
        await confirmOwner();
        assert(old.id===cached.id&&stripeId(old.customer)===customer&&old.client_reference_id===teamId&&old.mode==='subscription',502,'billing_provider_error','The saved checkout could not be verified.');
        if(old.status==='open')return json({url:providerURL(old.url,'checkout.stripe.com')});
        if(old.status==='complete'){
          const prior=current.subscriptions.find(s=>s.id===stripeId(old.subscription));
          assert(prior&&TERMINAL_SUBSCRIPTIONS.has(prior.status),409,'billing_processing','Payment is processing. Refresh your account shortly.');
        }else assert(old.status==='expired',502,'billing_provider_error','The saved checkout returned an invalid status.');
        await this.ctx.storage.delete(`checkout:${teamId}`);
      }
      const requestKey=(await this.ctx.storage.get<string>(`checkout-attempt:${teamId}`))??uuid();await this.ctx.storage.put(`checkout-attempt:${teamId}`,requestKey);
      const checkout=await stripe(this.env,'/checkout/sessions','POST',{
        mode:'subscription',customer,currency:'usd',client_reference_id:teamId,'metadata[teamId]':teamId,'subscription_data[metadata][teamId]':teamId,
        'line_items[0][price]':this.env.STRIPE_TEAM_PRICE_ID,'line_items[0][quantity]':'1',allow_promotion_codes:'false',
        success_url:`${base}/billing/return?team=${encodeURIComponent(teamId)}`,cancel_url:`${base}/billing/return?team=${encodeURIComponent(teamId)}&canceled=1`
      },`scriv-checkout-${teamId}-${requestKey}`);
      const checkoutURL=providerURL(checkout.url,'checkout.stripe.com');
      assert(typeof checkout.id==='string'&&checkout.id.length<=128&&timestamp(checkout.expires_at)>Date.now(),502,'billing_provider_error','The checkout response was invalid.');
      // Store the receipt and retire its idempotency key in one durable write.
      await this.ctx.storage.transaction(async txn=>{await txn.put(`checkout:${teamId}`,{id:checkout.id,expiresAt:timestamp(checkout.expires_at)});await txn.delete(`checkout-attempt:${teamId}`);});
      await confirmOwner();
      return json({url:checkoutURL});
    });}catch(error){return failure(error);}
  }
}

export async function verifyStripeSignature(raw:string,signature:string,secret:string,now=Date.now()):Promise<boolean>{
  const fields=signature.split(',').map(v=>v.trim().split('='));const timestamp=fields.find(([key])=>key==='t')?.[1];
  if(!timestamp||!/^\d+$/.test(timestamp)||!Number.isSafeInteger(Number(timestamp))||Math.abs(now/1000-Number(timestamp))>300)return false;
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
  let parsed:unknown;try{parsed=JSON.parse(raw);}catch{throw new APIError(400,'invalid_json','Invalid webhook body.');}
  const event=record(parsed,'event') as StripeObject;
  const eventId=str(event.id,'event.id',128),type=str(event.type,'event.type',128);
  const accepted=['checkout.session.completed','checkout.session.async_payment_succeeded','customer.subscription.created','customer.subscription.updated','customer.subscription.deleted','invoice.paid','invoice.payment_failed'];
  if(!accepted.includes(type))return json({received:true,ignored:true});
  const object=event.data?.object;assert(object&&typeof object==='object'&&!Array.isArray(object),400,'invalid_event','Webhook object is missing.');
  const customer=stripeId(object.customer);
  assert(customer&&customer.length<=128,400,'invalid_customer','Webhook customer is missing.');
  assert(timestamp(event.created)>0,400,'invalid_event','Webhook creation time is missing or invalid.');
  const team=await env.DB.prepare('SELECT id FROM teams WHERE stripe_customer_id=?').bind(customer).first<{id:string}>();
  if(!team)return json({received:true,ignored:true});
  const rpc=env.BILLING.get(env.BILLING.idFromName(team.id)) as unknown as BillingRPC;
  // Durable Object RPC serializes thrown errors, so the local APIError prototype
  // does not survive the boundary. Keep provider/reconciliation failure retryable.
  try{const result=await rpc.reconcile(team.id,eventId,type,timestamp(event.created));assert(!result.retry,502,'billing_reconciliation_failed','Billing confirmation needs a retry.');}
  catch{throw new APIError(502,'billing_reconciliation_failed','Billing confirmation is temporarily unavailable. The provider should retry this event.');}
  return json({received:true});
}
export async function billingRoutes(request:Request,env:Env,identity:Identity):Promise<Response|null>{
  const match=/^\/v1\/teams\/([^/]+)\/billing\/(checkout|portal)$/.exec(new URL(request.url).pathname);if(!match)return null;
  const teamId=id(match[1]);await requireTeam(env,teamId,identity.user.id,['owner']);await rateLimit(env,`billing:${identity.user.id}`,30,3600000);
  // There are no client-controlled prices or quantities on these routes.
  // Drain/bound an optional body before passing this request across the DO boundary.
  await bytes(request,4096);
  return env.BILLING.get(env.BILLING.idFromName(teamId)).fetch(new Request(request,{body:null}));
}
export function billingReturn(request:Request):Response{
  const team=new URL(request.url).searchParams.get('team')??'';const href=`scriv://billing/${encodeURIComponent(team)}`;
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Scriv billing</title><style>body{font:17px system-ui;max-width:32rem;margin:12vh auto;padding:2rem;background:#f5f7fc;color:#17213b}a{color:#1769ff}</style><h1>Return to your story.</h1><p>Scriv will update your team when the billing provider confirms your subscription.</p><a href="${escapeHTML(href)}">Open Scriv</a></html>`,{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store','content-security-policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"}});
}
export async function reconcileBilling(env:Env):Promise<void>{
  const teams=await env.DB.prepare('SELECT id FROM teams WHERE stripe_customer_id IS NOT NULL AND (billing_checked_at IS NULL OR billing_checked_at<?) ORDER BY COALESCE(billing_checked_at,0) LIMIT 100').bind(Date.now()-6*3600000).all<{id:string}>();
  for(let i=0;i<teams.results.length;i+=5)await Promise.allSettled(teams.results.slice(i,i+5).map(team=>(env.BILLING.get(env.BILLING.idFromName(team.id)) as unknown as BillingRPC).reconcile(team.id)));
}
