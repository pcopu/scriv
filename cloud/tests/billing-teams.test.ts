import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, reset, runInDurableObject } from 'cloudflare:test';
import type { Env, Role } from '../src/types';
import { sha256 } from '../src/http';
import { verifyStripeSignature } from '../src/billing';
const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[]},app=(exports as any).default,DAY=86400000;
const price={id:'price_scriv_team',active:true,currency:'usd',unit_amount:999,type:'recurring',billing_scheme:'per_unit',recurring:{interval:'month',interval_count:1,usage_type:'licensed'},transform_quantity:null,custom_unit_amount:null};
beforeEach(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
afterEach(async()=>{vi.restoreAllMocks();await reset();});
async function user(name='Writer'){const uid=crypto.randomUUID(),token=crypto.randomUUID(),sid=crypto.randomUUID();await env.DB.prepare('INSERT INTO users(id,github_id,name,created_at)VALUES(?,?,?,?)').bind(uid,uid,name,Date.now()).run();await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)VALUES(?,?,?,?,?,?)').bind(await sha256(token),sid,uid,'Test Mac',Date.now(),Date.now()+DAY).run();return{uid,token,sid};}
async function call(path:string,token?:string,method='GET',payload?:unknown){const r=await app.fetch(`https://scriv.test${path}`,{method,headers:{...(token?{authorization:`Bearer ${token}`} : {}),...(payload===undefined?{}:{'content-type':'application/json'})},body:payload===undefined?undefined:JSON.stringify(payload)});return{status:r.status,data:await r.json() as any};}
async function team(owner:Awaited<ReturnType<typeof user>>,paid=false){const r=await call('/v1/teams',owner.token,'POST',{name:'Writers'});expect(r.status).toBe(201);const id=r.data.team.id as string;await env.DB.prepare('UPDATE teams SET stripe_customer_id=?,subscription_status=?,paid_until=?,current_period_end=? WHERE id=?').bind(`cus_${id}`,paid?'active':'free',paid?Date.now()+DAY:null,paid?Date.now()+DAY:null,id).run();return id;}
async function member(teamId:string,role:Role='member'){const u=await user(role);await env.DB.prepare('INSERT INTO team_members VALUES(?,?,?,?)').bind(teamId,u.uid,role,Date.now()).run();return u;}
function sub(teamId:string,overrides:Record<string,unknown>={}){return{id:`sub_${teamId}`,customer:`cus_${teamId}`,status:'active',created:100,metadata:{teamId},items:{data:[{quantity:1,price,current_period_end:Math.floor(Date.now()/1000)+86400}],has_more:false},...overrides};}
function session(teamId:string,overrides:Record<string,unknown>={}){return{id:`cs_${teamId}`,customer:`cus_${teamId}`,client_reference_id:teamId,mode:'subscription',status:'open',url:`https://checkout.stripe.com/c/pay/cs_${teamId}`,expires_at:Math.floor(Date.now()/1000)+86400,...overrides};}
function stripe(handler:(path:string,init:RequestInit)=>unknown|Promise<unknown>){return vi.spyOn(globalThis,'fetch').mockImplementation(async(input:any,init?:RequestInit)=>{const url=new URL(String(input));expect(url.origin).toBe('https://api.stripe.com');expect(new Headers(init?.headers).get('Stripe-Version')).toBe('2025-04-30.basil');const value=await handler(url.pathname+url.search,init??{});return value instanceof Response?value:new Response(JSON.stringify(value),{headers:{'content-type':'application/json'}});});}
async function signed(payload:unknown,timestamp=Math.floor(Date.now()/1000)){const raw=JSON.stringify(payload),key=await crypto.subtle.importKey('raw',new TextEncoder().encode('whsec_test'),{name:'HMAC',hash:'SHA-256'},false,['sign']),signature=Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`${timestamp}.${raw}`))),b=>b.toString(16).padStart(2,'0')).join('');return{raw,header:`t=${timestamp},v1=${signature}`};}
async function webhook(payload:unknown){const value=await signed(payload),r=await app.fetch('https://scriv.test/billing/webhook',{method:'POST',body:value.raw,headers:{'stripe-signature':value.header}});return{status:r.status,data:await r.json() as any};}
const event=(t:string,type='customer.subscription.updated',created=100)=>({id:`evt_${crypto.randomUUID()}`,type,created,data:{object:{customer:`cus_${t}`}}});
const row=(t:string)=>env.DB.prepare('SELECT * FROM teams WHERE id=?').bind(t).first<any>();
const checkout=(t:string,token:string)=>call(`/v1/teams/${t}/billing/checkout`,token,'POST',{quantity:500,amount:1});
async function cached(t:string){await runInDurableObject(env.BILLING.get(env.BILLING.idFromName(t)),async(_instance,state)=>{await state.storage.put(`checkout:${t}`,{id:`cs_${t}`,expiresAt:Date.now()-DAY});});}

describe('per-team checkout safety',()=>{
 it('advertises one $9.99 plan with unlimited seats and authorizes only the owner to bill',async()=>{
  const owner=await user(),t=await team(owner),outsider=await user(),provider=stripe(()=>{throw Error('Unauthorized provider access');});
  const config=(await call('/v1/config',owner.token)).data;expect(config.teamPrice).toEqual({currency:'usd',amount:999,interval:'month'});expect(config.seatLimit).toBeNull();
  for(const role of ['admin','member','viewer'] as Role[]){const u=await member(t,role);for(const action of ['checkout','portal'])expect((await call(`/v1/teams/${t}/billing/${action}`,u.token,'POST')).status).toBe(403);}
  expect((await checkout(t,outsider.token)).status).toBe(404);expect((await call(`/v1/teams/${t}/billing/checkout`,undefined,'POST')).status).toBe(401);
  await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(),owner.sid).run();expect((await checkout(t,owner.token)).status).toBe(401);expect(provider).not.toHaveBeenCalled();
 });
 it('serializes repeated clicks into one quantity-one USD checkout and never grants access on redirect',async()=>{
  const owner=await user(),t=await team(owner);let created=0;
  stripe((path,init)=>{if(path.startsWith('/v1/prices/'))return price;if(path.startsWith('/v1/subscriptions?'))return{data:[],has_more:false};if(path==='/v1/checkout/sessions'&&init.method==='POST'){created++;const form=new URLSearchParams(String(init.body));expect(form.get('line_items[0][quantity]')).toBe('1');expect(form.get('line_items[0][price]')).toBe(price.id);expect(form.get('currency')).toBe('usd');expect(form.get('subscription_data[metadata][teamId]')).toBe(t);expect(form.get('allow_promotion_codes')).toBe('false');expect(form.has('line_items[1][price]')).toBe(false);expect(new Headers(init.headers).get('Idempotency-Key')).toContain(`scriv-checkout-${t}-`);return session(t);}expect(path).toBe(`/v1/checkout/sessions/cs_${t}`);return session(t);});
  const attempts=await Promise.all(Array.from({length:3},()=>checkout(t,owner.token)));expect(attempts.map(r=>r.status)).toEqual([200,200,200]);expect(new Set(attempts.map(r=>r.data.url)).size).toBe(1);expect(created).toBe(1);
  expect((await app.fetch(`https://scriv.test/billing/return?team=${t}`)).status).toBe(200);expect((await row(t)).subscription_status).toBe('free');expect((await row(t)).paid_until).toBe(0);
 });
 it.each([{unit_amount:1000},{currency:'eur'},{active:false},{type:'one_time'},{billing_scheme:'tiered'},{transform_quantity:{divide_by:10,round:'up'}},{custom_unit_amount:{enabled:true}},{recurring:{...price.recurring,interval:'year'}},{recurring:{...price.recurring,usage_type:'metered'}},{recurring:{...price.recurring,interval_count:2}}])('rejects a price outside the fixed Team contract: %j',async invalid=>{
  const owner=await user(),t=await team(owner),provider=stripe(path=>{expect(path).toBe(`/v1/prices/${price.id}`);return{...price,...invalid};});expect((await checkout(t,owner.token)).data.error.code).toBe('invalid_team_price');expect(provider).toHaveBeenCalledTimes(1);
 });
 it('repairs stale entitlement before another checkout after a missed payment webhook',async()=>{
  const owner=await user(),t=await team(owner);await cached(t);stripe(path=>{if(path.startsWith('/v1/prices/'))return price;expect(path).toContain('/v1/subscriptions?');return{data:[sub(t)],has_more:false};});const r=await checkout(t,owner.token);expect(r.status).toBe(409);expect(r.data.error.code).toBe('already_subscribed');expect((await row(t)).subscription_status).toBe('active');
 });
 it.each(['incomplete','past_due','unpaid','paused'])('directs %s subscriptions to the portal instead of charging again',async status=>{
  const owner=await user(),t=await team(owner);stripe(path=>path.startsWith('/v1/prices/')?price:{data:[sub(t,{status})],has_more:false});const r=await checkout(t,owner.token);expect(r.status).toBe(409);expect(r.data.error.code).toBe('subscription_exists');
 });
 it('keeps a completed payment pending after the cached checkout expiry',async()=>{
  const owner=await user(),t=await team(owner);await cached(t);stripe(path=>{if(path.startsWith('/v1/prices/'))return price;if(path.startsWith('/v1/subscriptions?'))return{data:[],has_more:false};expect(path).toBe(`/v1/checkout/sessions/cs_${t}`);return session(t,{status:'complete',url:null,subscription:'sub_pending'});});expect((await checkout(t,owner.token)).data.error.code).toBe('billing_processing');
 });
 it('allows a new checkout once the previous completed subscription is canceled',async()=>{
  const owner=await user(),t=await team(owner);await cached(t);stripe((path,init)=>{if(path.startsWith('/v1/prices/'))return price;if(path.startsWith('/v1/subscriptions?'))return{data:[sub(t,{status:'canceled'})],has_more:false};if(init.method==='POST')return session(t,{id:'cs_new'});return session(t,{status:'complete',subscription:`sub_${t}`});});expect((await checkout(t,owner.token)).status).toBe(200);
 });
 it('reuses the idempotency key after an ambiguous transport failure',async()=>{
  const owner=await user(),t=await team(owner),keys:string[]=[];stripe((path,init)=>{if(path.startsWith('/v1/prices/'))return price;if(path.startsWith('/v1/subscriptions?'))return{data:[],has_more:false};keys.push(new Headers(init.headers).get('Idempotency-Key')!);if(keys.length===1)throw Error('Connection lost after provider may have committed');return session(t);});expect((await checkout(t,owner.token)).status).toBe(502);expect((await checkout(t,owner.token)).status).toBe(200);expect(keys).toHaveLength(2);expect(keys[0]).toBe(keys[1]);
 });
 it('offers an inactive customer the recovery portal without creating customers just to open it',async()=>{
  const owner=await user(),t=await team(owner);stripe((path,init)=>{expect(path).toBe('/v1/billing_portal/sessions');expect(new URLSearchParams(String(init.body)).get('customer')).toBe(`cus_${t}`);return{url:'https://billing.stripe.com/p/session/test'};});expect((await call(`/v1/teams/${t}/billing/portal`,owner.token,'POST')).status).toBe(200);await env.DB.prepare('UPDATE teams SET stripe_customer_id=NULL WHERE id=?').bind(t).run();expect((await call(`/v1/teams/${t}/billing/portal`,owner.token,'POST')).data.error.code).toBe('billing_customer_required');
 });
 it.each(['https://billing.stripe.com.evil.test/path','https://billing.stripe.com@evil.test/path','http://billing.stripe.com/path','javascript:alert(1)'])('rejects unsafe provider URL %s',async url=>{const owner=await user(),t=await team(owner);stripe(()=>({url}));expect((await call(`/v1/teams/${t}/billing/portal`,owner.token,'POST')).status).toBe(502);});
});

describe('canonical billing reconciliation',()=>{
 it('isolates teams owned by one account and rejects mismatched team, quantity, price, or extra items',async()=>{
  const owner=await user(),a=await team(owner),b=await team(owner),item=sub(a).items.data[0];stripe(()=>({data:[sub(a,{metadata:{teamId:b}}),sub(a,{items:{data:[{...item,quantity:2}]}}),sub(a,{items:{data:[{...item,price:{id:'price_other'}}]}}),sub(a,{items:{data:[item,item]}})],has_more:false}));expect((await webhook(event(a))).status).toBe(200);expect((await row(a)).subscription_status).toBe('free');expect((await row(b)).billing_checked_at).toBeNull();
 });
 it('keeps renewed subscriptions active through old cancellations and duplicate delivery',async()=>{
  const owner=await user(),t=await team(owner,true),provider=stripe(()=>({data:[sub(t,{id:'sub_old',status:'canceled',created:1}),sub(t,{id:'sub_new',created:200})],has_more:false})),renewal=event(t,'invoice.paid',200),cancellation=event(t,'customer.subscription.deleted',1);
  expect((await webhook(renewal)).status).toBe(200);expect((await webhook(cancellation)).status).toBe(200);expect((await webhook(cancellation)).status).toBe(200);expect((await row(t)).subscription_id).toBe('sub_new');expect(provider).toHaveBeenCalledTimes(2);expect((await env.DB.prepare('SELECT COUNT(*) n FROM billing_events WHERE team_id=?').bind(t).first<any>()).n).toBe(2);
 });
 it.each([{}, {data:null,has_more:false}, {data:[],has_more:true}, {data:[null],has_more:false}])('preserves known entitlement on incomplete provider history %j',async bad=>{
  const owner=await user(),t=await team(owner,true),before=await row(t);stripe(()=>bad);expect((await webhook(event(t))).status).toBe(502);expect((await row(t)).paid_until).toBe(before.paid_until);expect((await row(t)).subscription_status).toBe('active');expect((await env.DB.prepare('SELECT COUNT(*) n FROM billing_events').first<any>()).n).toBe(0);
 });
 it('reads every provider page before choosing canonical state',async()=>{
  const owner=await user(),t=await team(owner);let requests=0;stripe(path=>{if(++requests===1)return{data:[sub(t,{id:'sub_old',status:'canceled'})],has_more:true};expect(new URL(`https://api.stripe.com${path}`).searchParams.get('starting_after')).toBe('sub_old');return{data:[sub(t,{id:'sub_new',created:200})],has_more:false};});expect((await webhook(event(t))).status).toBe(200);expect((await row(t)).subscription_id).toBe('sub_new');expect(requests).toBe(2);
 });
 it('uses the Basil item period instead of an unrelated future trial date',async()=>{
  const owner=await user(),t=await team(owner),end=Math.floor(Date.now()/1000)-60;stripe(()=>({data:[sub(t,{trial_end:Math.floor(Date.now()/1000)+864000,items:{data:[{quantity:1,price,current_period_end:end}]}})],has_more:false}));expect((await webhook(event(t))).status).toBe(200);expect((await row(t)).paid_until).toBe(end*1000);expect((await call('/v1/teams',owner.token)).data.teams[0].plan).toBe('free');
 });
 it('does not restart read grace when cancellation arrives 40 days late',async()=>{
  const owner=await user(),t=await team(owner,true),writer=await member(t),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id,ended=Math.floor((Date.now()-40*DAY)/1000);stripe(()=>({data:[sub(t,{status:'canceled',ended_at:ended,items:{data:[{quantity:1,price,current_period_end:ended}]}})],has_more:false}));expect((await webhook(event(t))).status).toBe(200);expect((await row(t)).canceled_at).toBe(ended*1000);expect((await call(`/v1/projects/${p}`,writer.token)).status).toBe(402);expect((await call(`/v1/projects/${p}`,owner.token)).status).toBe(200);
 });
 it('validates signed event envelopes and rotated signatures, rejecting stale/altered payloads',async()=>{
  for(const invalid of [null,[],1,'event',{id:'evt_bad',type:'customer.subscription.updated',data:{object:{}}},{id:'evt_bad',type:'customer.subscription.updated',created:'100',data:{object:{customer:'cus_bad'}}}])expect((await webhook(invalid)).status).toBe(400);
  const value=await signed({id:'evt_unknown',type:'ignored'});expect(await verifyStripeSignature(value.raw,`${value.header}, v1=${'0'.repeat(64)}`,'whsec_test')).toBe(true);expect(await verifyStripeSignature(value.raw+' ',value.header,'whsec_test')).toBe(false);expect(await verifyStripeSignature(value.raw,value.header,'whsec_test',Date.now()+600000)).toBe(false);
 });
});

describe('invitations, membership and lapsed access',()=>{
 it('stores only hashed reusable invitations and preserves existing membership roles',async()=>{
  const owner=await user(),t=await team(owner,true),admin=await member(t,'admin'),newcomer=await user(),invitation=(await call(`/v1/teams/${t}/join-links`,owner.token,'POST',{role:'viewer',expiresInDays:1})).data,stored=await env.DB.prepare('SELECT * FROM join_links WHERE id=?').bind(invitation.link.id).first<any>();expect(stored.token_hash).toBe(await sha256(invitation.token));expect(JSON.stringify(stored)).not.toContain(invitation.token);
  expect((await call(`/v1/join/${invitation.token}`,admin.token,'POST')).data.team.role).toBe('admin');expect((await call(`/v1/join/${invitation.token}`,owner.token,'POST')).data.team.role).toBe('owner');for(let i=0;i<2;i++)expect((await call(`/v1/join/${invitation.token}`,newcomer.token,'POST')).data.team.role).toBe('viewer');expect((await env.DB.prepare('SELECT COUNT(*) n FROM team_members WHERE team_id=?').bind(t).first<any>()).n).toBe(3);
 });
 it('rejects expired, revoked, unsigned and unpaid invitations without cross-team revocation',async()=>{
  const owner=await user(),t=await team(owner,true),other=await team(owner,true),newcomer=await user(),invite=(await call(`/v1/teams/${t}/join-links`,owner.token,'POST',{role:'member'})).data,path=`/v1/join/${invite.token}`;expect((await call(path,undefined,'POST')).status).toBe(401);await call(`/v1/teams/${other}/join-links/${invite.link.id}`,owner.token,'DELETE');expect((await call(path,newcomer.token,'POST')).status).toBe(200);
  await env.DB.prepare("UPDATE teams SET subscription_status='past_due' WHERE id=?").bind(t).run();expect((await call(path,newcomer.token,'POST')).status).toBe(402);await env.DB.prepare("UPDATE teams SET subscription_status='active' WHERE id=?").bind(t).run();await env.DB.prepare('UPDATE join_links SET expires_at=0 WHERE id=?').bind(invite.link.id).run();expect((await call(path,newcomer.token,'POST')).status).toBe(404);await env.DB.prepare('UPDATE join_links SET expires_at=? WHERE id=?').bind(Date.now()+DAY,invite.link.id).run();await call(`/v1/teams/${t}/join-links/${invite.link.id}`,owner.token,'DELETE');expect((await call(path,newcomer.token,'POST')).status).toBe(404);
 });
 it('enforces owner/admin/member boundaries and lets non-owners leave safely',async()=>{
  const owner=await user(),t=await team(owner,true),admin=await member(t,'admin'),otherAdmin=await member(t,'admin'),writer=await member(t),viewer=await member(t,'viewer'),path=(id:string)=>`/v1/teams/${t}/members/${id}`;
  expect((await call(path(owner.uid),owner.token,'DELETE')).status).toBe(409);expect((await call(path(otherAdmin.uid),admin.token,'DELETE')).status).toBe(403);expect((await call(path(writer.uid),admin.token,'PATCH',{role:'admin'})).status).toBe(403);expect((await call(path(writer.uid),viewer.token,'PATCH',{role:'member'})).status).toBe(403);expect((await call(path(writer.uid),admin.token,'PATCH',{role:'viewer'})).status).toBe(200);expect((await call(path(writer.uid),owner.token,'PATCH',{role:'admin'})).status).toBe(200);expect((await call(path(admin.uid),admin.token,'DELETE')).status).toBe(200);expect((await call(path(viewer.uid),viewer.token,'DELETE')).status).toBe(200);expect((await call(`/v1/teams/${t}`,viewer.token)).status).toBe(404);expect((await call(`/v1/teams/${t}/join-links`,writer.token,'POST',{role:'owner'})).status).toBe(400);
 });
 it('makes the cancellation grace period read/export-only for admins, preserving owner access',async()=>{
  const owner=await user(),t=await team(owner,true),admin=await member(t,'admin'),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id;await env.DB.prepare("UPDATE teams SET subscription_status='canceled',canceled_at=? WHERE id=?").bind(Date.now()-DAY,t).run();expect((await call(`/v1/projects/${p}`,admin.token)).status).toBe(200);expect((await call(`/v1/projects/${p}`,admin.token,'PATCH',{title:'Bad rename'})).status).toBe(403);expect((await call(`/v1/projects/${p}`,admin.token,'DELETE')).status).toBe(403);expect((await call(`/v1/projects/${p}`,owner.token,'PATCH',{title:'Owner retained'})).status).toBe(200);await env.DB.prepare('UPDATE teams SET canceled_at=? WHERE id=?').bind(Date.now()-31*DAY,t).run();expect((await call('/v1/projects',admin.token)).data.projects).toHaveLength(0);expect((await call(`/v1/projects/${p}`,owner.token)).status).toBe(200);
 });
 it('denies stale catalog owners access to team-owned projects after removal',async()=>{
  const owner=await user(),t=await team(owner,true),removed=await user(),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id;await env.DB.prepare('UPDATE projects SET owner_id=? WHERE id=?').bind(removed.uid,p).run();expect((await call(`/v1/projects/${p}`,removed.token)).status).toBe(404);expect((await call('/v1/projects',removed.token)).data.projects).toHaveLength(0);expect((await call(`/v1/projects/${p}`,owner.token)).status).toBe(200);
 });
 it('returns the actual rename time and rejects replaying archived project IDs',async()=>{
  const owner=await user();expect((await call('/v1/projects',owner.token,'POST',{id:'project-replay',title:'Film'})).status).toBe(201);const changed=await call('/v1/projects/project-replay',owner.token,'PATCH',{title:'New name'});expect(changed.data.project.updatedAt).toBe((await env.DB.prepare('SELECT updated_at FROM projects WHERE id=?').bind('project-replay').first<any>()).updated_at);await call('/v1/projects/project-replay',owner.token,'DELETE');expect((await call('/v1/projects',owner.token,'POST',{id:'project-replay',title:'New name'})).data.error.code).toBe('project_archived');
 });
});

describe('authorization race and propagation regressions',()=>{
 it('rechecks invite revocation atomically at membership insertion',async()=>{
  const {teamRoutes}=await import('../src/teams'),{authenticate}=await import('../src/access');
  const owner=await user(),t=await team(owner,true),newcomer=await user(),invite=(await call(`/v1/teams/${t}/join-links`,owner.token,'POST',{role:'member'})).data;
  const request=new Request(`https://scriv.test/v1/join/${invite.token}`,{method:'POST',headers:{authorization:`Bearer ${newcomer.token}`}}),identity=await authenticate(request,env);
  let intercepted=false;
  const db={prepare(sql:string){const statement=env.DB.prepare(sql);if(!sql.includes('INSERT INTO team_members'))return statement;return{bind(...values:unknown[]){const bound=statement.bind(...values);return{async run(){intercepted=true;await env.DB.prepare('UPDATE join_links SET revoked_at=? WHERE id=?').bind(Date.now(),invite.link.id).run();return bound.run();}};}};}} as unknown as D1Database;
  await expect(teamRoutes(request,{...env,DB:db},identity)).rejects.toMatchObject({status:404,code:'invite_invalid'});
  expect(intercepted).toBe(true);expect(await env.DB.prepare('SELECT user_id FROM team_members WHERE team_id=? AND user_id=?').bind(t,newcomer.uid).first()).toBeNull();
 });
 it('rechecks actor authority atomically when membership changes during a role update',async()=>{
  const {teamRoutes}=await import('../src/teams'),{authenticate}=await import('../src/access');
  const owner=await user(),t=await team(owner,true),admin=await member(t,'admin'),writer=await member(t);
  const request=new Request(`https://scriv.test/v1/teams/${t}/members/${writer.uid}`,{method:'PATCH',headers:{authorization:`Bearer ${admin.token}`,'content-type':'application/json'},body:JSON.stringify({role:'viewer'})}),identity=await authenticate(request,env);
  const db={prepare(sql:string){const statement=env.DB.prepare(sql);if(!sql.includes('UPDATE team_members SET role='))return statement;return{bind(...values:unknown[]){const bound=statement.bind(...values);return{async first(){await env.DB.prepare('DELETE FROM team_members WHERE team_id=? AND user_id=?').bind(t,admin.uid).run();return bound.first();}};}};}} as unknown as D1Database;
  await expect(teamRoutes(request,{...env,DB:db},identity)).rejects.toMatchObject({status:409,code:'membership_changed'});
  expect((await env.DB.prepare('SELECT role FROM team_members WHERE team_id=? AND user_id=?').bind(t,writer.uid).first<any>()).role).toBe('member');
 });
 it('retrying a processed event propagates access changes again without replaying provider state',async()=>{
  const owner=await user(),t=await team(owner,true),writer=await member(t),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id;
  const provider=stripe(()=>({data:[sub(t)],has_more:false})),delivery=event(t);
  expect((await webhook(delivery)).status).toBe(200);
  const response=await app.fetch(`https://scriv.test/v1/projects/${p}/socket`,{headers:{authorization:`Bearer ${writer.token}`,upgrade:'websocket'}});
  expect(response.status).toBe(101);const socket=response.webSocket!;
  const hello=new Promise<void>(resolve=>socket.addEventListener('message',(e:MessageEvent)=>{if(JSON.parse(String(e.data)).type==='hello')resolve();}));socket.accept();await hello;
  const closed=new Promise<number>((resolve,reject)=>{const timeout=setTimeout(()=>reject(Error('Access refresh did not close socket')),3000);socket.addEventListener('close',(e:CloseEvent)=>{clearTimeout(timeout);resolve(e.code);});});
  try{await env.DB.prepare('DELETE FROM team_members WHERE team_id=? AND user_id=?').bind(t,writer.uid).run();expect((await webhook(delivery)).status).toBe(200);expect(await closed).toBe(4001);expect(provider).toHaveBeenCalledTimes(1);}finally{socket.close();}
 });
});

describe('slow request body authorization fences',()=>{
 function paused(path:string,token:string,method:string,payload:unknown){
  let start!:()=>void,controller!:ReadableStreamDefaultController<Uint8Array>;
  const started=new Promise<void>(resolve=>{start=resolve;});
  const stream=new ReadableStream<Uint8Array>({start(c){controller=c;},pull(){start();}},{highWaterMark:0});
  return{request:new Request(`https://scriv.test${path}`,{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:stream}),started,finish(){controller.enqueue(new TextEncoder().encode(JSON.stringify(payload)));controller.close();}};
 }
 it.each(['team-rename','invite-create','project-rename'])('cannot finish %s after administrator removal completes',async action=>{
  const {teamRoutes}=await import('../src/teams'),{authenticate}=await import('../src/access');
  const owner=await user(),t=await team(owner,true),admin=await member(t,'admin'),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id;
  const path=action==='team-rename'?`/v1/teams/${t}`:action==='invite-create'?`/v1/teams/${t}/join-links`:`/v1/projects/${p}`;
  const pending=paused(path,admin.token,action==='invite-create'?'POST':'PATCH',action==='invite-create'?{role:'member'}:action==='team-rename'?{name:'Unauthorized'}:{title:'Unauthorized'});
  const identity=await authenticate(pending.request,env),result=teamRoutes(pending.request,env,identity);
  await pending.started;
  expect((await call(`/v1/teams/${t}/members/${admin.uid}`,owner.token,'DELETE')).status).toBe(200);
  pending.finish();await expect(result).rejects.toMatchObject({status:409,code:'access_changed'});
  expect((await row(t)).name).toBe('Writers');expect((await env.DB.prepare('SELECT title FROM projects WHERE id=?').bind(p).first<any>()).title).toBe('Film');
  expect((await env.DB.prepare('SELECT COUNT(*) n FROM join_links WHERE team_id=?').bind(t).first<any>()).n).toBe(0);
 });
 it('cannot create a team after the initiating device is revoked while its body is pending',async()=>{
  const {teamRoutes}=await import('../src/teams'),{authenticate}=await import('../src/access');const owner=await user();
  const pending=paused('/v1/teams',owner.token,'POST',{name:'Unauthorized'}),identity=await authenticate(pending.request,env),result=teamRoutes(pending.request,env,identity);
  await pending.started;await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(),owner.sid).run();pending.finish();
  await expect(result).rejects.toMatchObject({status:401,code:'session_expired'});expect((await env.DB.prepare('SELECT COUNT(*) n FROM teams').first<any>()).n).toBe(0);expect((await env.DB.prepare('SELECT COUNT(*) n FROM team_members').first<any>()).n).toBe(0);
 });
 it('cannot rename a team project after payment lapses while an admin body is pending',async()=>{
  const {teamRoutes}=await import('../src/teams'),{authenticate}=await import('../src/access');const owner=await user(),t=await team(owner,true),admin=await member(t,'admin'),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id;
  const pending=paused(`/v1/projects/${p}`,admin.token,'PATCH',{title:'Unauthorized'}),identity=await authenticate(pending.request,env),result=teamRoutes(pending.request,env,identity);
  await pending.started;await env.DB.prepare("UPDATE teams SET subscription_status='canceled',canceled_at=? WHERE id=?").bind(Date.now(),t).run();pending.finish();
  await expect(result).rejects.toMatchObject({status:409,code:'access_changed'});expect((await env.DB.prepare('SELECT title FROM projects WHERE id=?').bind(p).first<any>()).title).toBe('Film');
 });
});

describe('media reservation and provider response authorization',()=>{
 it.each(['removed','viewer','lapsed','revoked','archived'])('does not reserve or upload media when access becomes %s while its body is pending',async change=>{
  const {mediaRoutes}=await import('../src/media'),{authenticate}=await import('../src/access');
  const owner=await user(),t=await team(owner,true),writer=await member(t),p=(await call('/v1/projects',owner.token,'POST',{title:'Film',teamId:t})).data.project.id;
  const content=new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,0]),hash=await sha256(content);
  let start!:()=>void,controller!:ReadableStreamDefaultController<Uint8Array>;
  const started=new Promise<void>(resolve=>{start=resolve;}),stream=new ReadableStream<Uint8Array>({start(c){controller=c;},pull(){start();}},{highWaterMark:0});
  const request=new Request(`https://scriv.test/v1/projects/${p}/assets/${hash}`,{method:'PUT',headers:{authorization:`Bearer ${writer.token}`,'content-type':'image/png'},body:stream}),identity=await authenticate(request,env),result=mediaRoutes(request,env,identity);
  await started;
  if(change==='removed')expect((await call(`/v1/teams/${t}/members/${writer.uid}`,owner.token,'DELETE')).status).toBe(200);
  if(change==='viewer')expect((await call(`/v1/teams/${t}/members/${writer.uid}`,owner.token,'PATCH',{role:'viewer'})).status).toBe(200);
  if(change==='lapsed')await env.DB.prepare("UPDATE teams SET subscription_status='canceled',canceled_at=? WHERE id=?").bind(Date.now(),t).run();
  if(change==='revoked')expect((await call('/auth/logout',writer.token,'POST')).status).toBe(200);
  if(change==='archived')expect((await call(`/v1/projects/${p}`,owner.token,'DELETE')).status).toBe(200);
  controller.enqueue(content);controller.close();await expect(result).rejects.toMatchObject({status:409,code:'upload_unavailable'});
  expect((await row(t)).storage_used).toBe(0);expect((await env.DB.prepare('SELECT COUNT(*) n FROM assets WHERE project_id=?').bind(p).first<any>()).n).toBe(0);expect(await env.MEDIA.head(`projects/${p}/${hash}`)).toBeNull();
 });
 it.each(['checkout','portal'])('does not release a %s URL after device revocation during the provider response',async action=>{
  const owner=await user(),t=await team(owner);let created=0;
  stripe(async(path,init)=>{
   if(path.startsWith('/v1/prices/'))return price;if(path.startsWith('/v1/subscriptions?'))return{data:[],has_more:false};
   expect(init.method).toBe('POST');expect(path).toBe(action==='checkout'?'/v1/checkout/sessions':'/v1/billing_portal/sessions');created++;
   // Inject revocation before the awaited provider result resolves. Keeping the
   // ordering inside the mock avoids sharing a deferred promise across workerd
   // request/DO contexts, which crashes the current local test runtime.
   await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(),owner.sid).run();
   return action==='checkout'?session(t):{url:'https://billing.stripe.com/p/session/test'};
  });
  const denied=await call(`/v1/teams/${t}/billing/${action}`,owner.token,'POST');expect(denied.status).toBe(401);expect(denied.data.url).toBeUndefined();expect(created).toBe(1);
  if(action==='checkout')await runInDurableObject(env.BILLING.get(env.BILLING.idFromName(t)),async(_instance,state)=>{expect((await state.storage.get<any>(`checkout:${t}`)).id).toBe(`cs_${t}`);expect(await state.storage.get(`checkout-attempt:${t}`)).toBeUndefined();});
 });
 it('checks session revocation before creating provider state after a delayed price lookup',async()=>{
  const owner=await user(),t=await team(owner);
  const provider=stripe(async(path)=>{expect(path).toBe(`/v1/prices/${price.id}`);await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(),owner.sid).run();return price;});
  expect((await checkout(t,owner.token)).status).toBe(401);expect(provider).toHaveBeenCalledTimes(1);
 });
});
