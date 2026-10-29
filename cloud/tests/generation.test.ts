import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, reset } from 'cloudflare:test';
import type { Env } from '../src/types';
import { authenticate } from '../src/access';
import { generationRoutes } from '../src/generation';
import { sha256 } from '../src/http';
const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[]},app=(exports as any).default,DAY=86400000;
beforeEach(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);vi.spyOn(globalThis,'fetch').mockImplementation(()=>{throw Error('Generation metadata must not call a provider.');});});
afterEach(async()=>{vi.restoreAllMocks();await reset();});
async function device(uid:string,name='Test Mac'){const token=crypto.randomUUID(),sid=crypto.randomUUID();await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)VALUES(?,?,?,?,?,?)').bind(await sha256(token),sid,uid,name,Date.now(),Date.now()+DAY).run();return{uid,token,sid};}
async function user(){const uid=crypto.randomUUID();await env.DB.prepare('INSERT INTO users(id,github_id,name,created_at)VALUES(?,?,?,?)').bind(uid,uid,'Writer',Date.now()).run();return await device(uid);}
async function call(path:string,token?:string,method='GET',payload?:unknown){const response=await app.fetch(`https://scriv.test${path}`,{method,headers:{...(token?{authorization:`Bearer ${token}`} : {}),...(payload===undefined?{}:{'content-type':'application/json'})},body:payload===undefined?undefined:JSON.stringify(payload)});return{status:response.status,data:await response.json() as any};}
async function project(owner:Awaited<ReturnType<typeof user>>,teamId?:string){const response=await call('/v1/projects',owner.token,'POST',{title:'Film',...(teamId?{teamId}:{})});expect(response.status).toBe(201);return response.data.project.id as string;}
const path=(projectId:string,jobId?:string)=>`/v1/projects/${projectId}/generation-jobs${jobId?`/${jobId}`:''}`;
const operation=(version:number,extra:Record<string,unknown>={})=>({operationId:crypto.randomUUID(),expectedVersion:version,...extra});
async function fixture(){const owner=await user(),p=await project(owner),input={id:crypto.randomUUID(),targetItemId:crypto.randomUUID(),sourceRevision:3};const created=await call(path(p),owner.token,'POST',input);expect(created.status).toBe(201);return{owner,p,input,job:created.data.job};}
async function claim(f:Awaited<ReturnType<typeof fixture>>,extra:Record<string,unknown>={}){return await call(`${path(f.p,f.input.id)}/claim`,f.owner.token,'POST',operation(f.job.version,extra));}
async function shared(){const owner=await user(),t=(await call('/v1/teams',owner.token,'POST',{name:'Writers'})).data.team.id as string;await env.DB.prepare("UPDATE teams SET subscription_status='active',paid_until=? WHERE id=?").bind(Date.now()+DAY,t).run();const writer=await user(),viewer=await user();for(const [u,role] of [[writer,'member'],[viewer,'viewer']] as const)await env.DB.prepare('INSERT INTO team_members VALUES(?,?,?,?)').bind(t,u.uid,role,Date.now()).run();return{owner,writer,viewer,t,p:await project(owner,t)};}

describe('durable local generation metadata',()=>{
 it('persists metadata, owns devices on the server, and creates idempotently without storing inputs',async()=>{
  const f=await fixture();expect(f.job).toMatchObject({schemaVersion:1,id:f.input.id,projectId:f.p,targetItemId:f.input.targetItemId,sourceRevision:3,status:'queued',createdBy:f.owner.uid,ownerDeviceId:f.owner.sid,ownerDeviceName:'Test Mac',version:1});
  expect(f.job.leaseExpiresAt).toBeGreaterThan(Date.now());expect((await call(path(f.p),f.owner.token,'POST',f.input)).data).toMatchObject({replayed:true,job:{version:1}});
  expect((await call(path(f.p),f.owner.token,'POST',{...f.input,sourceRevision:4})).status).toBe(409);
  for(const key of ['prompt','referencePaths','threadId','credentials','ownerDeviceId'])expect((await call(path(f.p),f.owner.token,'POST',{...f.input,[key]:'private'})).status).toBe(400);
  const rows=await env.DB.prepare('SELECT * FROM generation_jobs').all();expect(rows.results).toHaveLength(1);expect(JSON.stringify(rows)).not.toContain('private');
 });
 it('preserves opaque item references and uppercase UUID job identities',async()=>{
  const owner=await user(),p=await project(owner),jobId=crypto.randomUUID().toUpperCase(),input={id:jobId,targetItemId:'cue-08C',sourceRevision:0};
  expect((await call(path(p),owner.token,'POST',input)).data.job).toMatchObject({id:jobId,targetItemId:'cue-08C'});
  expect((await call(`${path(p,jobId)}/claim`,owner.token,'POST',operation(1))).status).toBe(200);
  expect((await call(path(p,jobId),owner.token,'PATCH',operation(2,{status:'completed',outputImageId:'IMAGE-Original'}))).data.job.outputImageId).toBe('IMAGE-Original');
 });
 it('claims, heartbeats, completes and replays current state without a second execution grant',async()=>{
  const f=await fixture(),start=operation(1),url=path(f.p,f.input.id);expect((await call(`${url}/claim`,f.owner.token,'POST',start)).data.job).toMatchObject({status:'running',version:2});
  const heartbeat=operation(2,{status:'running',progressText:'Preparing image'});expect((await call(url,f.owner.token,'PATCH',heartbeat)).data.job.version).toBe(3);expect((await call(url,f.owner.token,'PATCH',heartbeat)).data).toMatchObject({replayed:true,job:{version:3}});
  const output=crypto.randomUUID();expect((await call(url,f.owner.token,'PATCH',operation(3,{status:'completed',outputImageId:output}))).data.job).toMatchObject({status:'completed',version:4,outputImageId:output,leaseExpiresAt:0});
  expect((await call(`${url}/claim`,f.owner.token,'POST',start)).data).toMatchObject({replayed:true,job:{status:'completed',version:4}});
  expect((await call(`${url}/claim`,f.owner.token,'POST',operation(4,{recover:true}))).status).toBe(409);
  expect((await call(url,f.owner.token,'PATCH',operation(4,{status:'cancelled'}))).status).toBe(409);
  expect((await call(path(f.p),f.owner.token,'POST',f.input)).data.job.status).toBe('completed');
 });
 it('linearizes simultaneous claims and detects operation-ID payload reuse',async()=>{
  const f=await fixture(),url=`${path(f.p,f.input.id)}/claim`,requests=[operation(1),operation(1)];
  const responses=await Promise.all(requests.map(payload=>call(url,f.owner.token,'POST',payload)));expect(responses.map(r=>r.status).sort()).toEqual([200,409]);
  const accepted=requests[responses.findIndex(r=>r.status===200)]!;expect((await call(url,f.owner.token,'POST',{...accepted,recover:true})).status).toBe(409);
  const other=await fixture(),same=operation(1),duplicates=await Promise.all([call(`${path(other.p,other.input.id)}/claim`,other.owner.token,'POST',same),call(`${path(other.p,other.input.id)}/claim`,other.owner.token,'POST',same)]);expect(duplicates.map(r=>r.status)).toEqual([200,200]);expect(duplicates.map(r=>r.data.job.version)).toEqual([2,2]);
 });
 it.each(['expired','revoked'])('shows Waiting for this Mac when its owner is %s and explicitly recovers with a fence',async reason=>{
  const f=await fixture(),url=path(f.p,f.input.id),second=await device(f.owner.uid,'Recovery Mac');expect((await claim(f)).status).toBe(200);
  expect((await call(`${url}/claim`,second.token,'POST',operation(2,{recover:true}))).status).toBe(409);
  if(reason==='expired')await env.DB.prepare('UPDATE generation_jobs SET lease_expires_at=0 WHERE project_id=?').bind(f.p).run();else await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(),f.owner.sid).run();
  expect((await call(url,second.token)).data.job).toMatchObject({status:'waiting',progressText:'Waiting for this Mac',version:2});
  expect((await call(`${url}/claim`,second.token,'POST',operation(2))).status).toBe(409);
  expect((await call(`${url}/claim`,second.token,'POST',operation(2,{recover:true}))).data.job).toMatchObject({status:'running',version:3,ownerDeviceId:second.sid,ownerDeviceName:'Recovery Mac'});
  const stale=await call(url,f.owner.token,'PATCH',operation(2,{status:'completed',outputImageId:crypto.randomUUID()}));expect(stale.status).toBe(reason==='revoked'?401:409);
 });
 it('requires explicit recovery after failure or pause and preserves terminal receipts',async()=>{
  const f=await fixture(),url=path(f.p,f.input.id);await claim(f);
  expect((await call(url,f.owner.token,'PATCH',operation(2,{status:'failed',errorCode:'generation_failed'}))).data.job.status).toBe('failed');
  expect((await call(`${url}/claim`,f.owner.token,'POST',operation(3))).status).toBe(409);
  expect((await call(`${url}/claim`,f.owner.token,'POST',operation(3,{recover:true}))).data.job).toMatchObject({status:'running',version:4,errorCode:null});
  expect((await call(url,f.owner.token,'PATCH',operation(4,{status:'waiting',errorCode:'interrupted'}))).data.job).toMatchObject({status:'waiting',leaseExpiresAt:0});
  expect((await call(url,f.owner.token,'PATCH',operation(5,{status:'completed',outputImageId:crypto.randomUUID()}))).status).toBe(409);
 });
 it('limits control to its creator while authorized viewers can read, with project isolation',async()=>{
  const s=await shared(),input={id:crypto.randomUUID(),targetItemId:crypto.randomUUID(),sourceRevision:0},created=await call(path(s.p),s.writer.token,'POST',input);expect(created.status).toBe(201);
  expect((await call(path(s.p),s.viewer.token)).data.jobs).toHaveLength(1);expect((await call(path(s.p),s.viewer.token,'POST',{...input,id:crypto.randomUUID()})).status).toBe(403);
  expect((await call(`${path(s.p,input.id)}/claim`,s.owner.token,'POST',operation(1))).status).toBe(403);
  const outsider=await user(),other=await project(outsider);expect((await call(path(s.p),outsider.token)).status).toBe(404);expect((await call(path(other,input.id),outsider.token)).status).toBe(404);expect((await call(path(s.p))).status).toBe(401);
  await env.DB.prepare("UPDATE teams SET subscription_status='canceled',canceled_at=? WHERE id=?").bind(Date.now(),s.t).run();expect((await call(path(s.p),s.writer.token)).status).toBe(200);expect((await call(`${path(s.p,input.id)}/claim`,s.writer.token,'POST',operation(1))).status).toBe(403);
 });
 it('paginates deterministically even for identical timestamps and validates bounded input',async()=>{
  const f=await fixture();for(let i=0;i<3;i++)expect((await call(path(f.p),f.owner.token,'POST',{...f.input,id:crypto.randomUUID()})).status).toBe(201);await env.DB.prepare('UPDATE generation_jobs SET created_at=123 WHERE project_id=?').bind(f.p).run();
  const first=await call(`${path(f.p)}?limit=2`,f.owner.token),second=await call(`${path(f.p)}?limit=2&cursor=${encodeURIComponent(first.data.nextCursor)}`,f.owner.token);expect(first.data.jobs).toHaveLength(2);expect(second.data.jobs).toHaveLength(2);expect(second.data.nextCursor).toBeNull();expect(new Set([...first.data.jobs,...second.data.jobs].map(j=>j.id)).size).toBe(4);
  expect((await call(`${path(f.p)}?limit=101`,f.owner.token)).status).toBe(400);expect((await call(`${path(f.p)}?cursor=broken`,f.owner.token)).status).toBe(400);
  await claim(f);for(const payload of [{status:'completed'},{status:'running',outputImageId:crypto.randomUUID()},{status:'running',progressText:'a\nb'},{status:'failed',errorCode:'raw provider response'},{status:'running',progressText:'a'.repeat(5000)}])expect((await call(path(f.p,f.input.id),f.owner.token,'PATCH',operation(2,payload))).status).toBe(payload.progressText?.length===5000?413:400);
 });
});

describe('generation authorization at the delayed write boundary',()=>{
 it.each(['removed','viewer','lapsed','revoked','archived'])('cannot claim after access becomes %s while a body is pending',async change=>{
  const s=await shared(),input={id:crypto.randomUUID(),targetItemId:crypto.randomUUID(),sourceRevision:0};expect((await call(path(s.p),s.writer.token,'POST',input)).status).toBe(201);
  let started!:()=>void,controller!:ReadableStreamDefaultController<Uint8Array>;const ready=new Promise<void>(resolve=>{started=resolve;});
  const stream=new ReadableStream<Uint8Array>({start(c){controller=c;},pull(){started();}},{highWaterMark:0});
  const request=new Request(`https://scriv.test${path(s.p,input.id)}/claim`,{method:'POST',headers:{authorization:`Bearer ${s.writer.token}`,'content-type':'application/json'},body:stream});
  const identity=await authenticate(request,env),result=generationRoutes(request,env,identity);await ready;
  if(change==='removed')await env.DB.prepare('DELETE FROM team_members WHERE team_id=? AND user_id=?').bind(s.t,s.writer.uid).run();
  if(change==='viewer')await env.DB.prepare("UPDATE team_members SET role='viewer' WHERE team_id=? AND user_id=?").bind(s.t,s.writer.uid).run();
  if(change==='lapsed')await env.DB.prepare("UPDATE teams SET subscription_status='canceled',canceled_at=? WHERE id=?").bind(Date.now(),s.t).run();
  if(change==='revoked')await env.DB.prepare('UPDATE sessions SET revoked_at=? WHERE id=?').bind(Date.now(),s.writer.sid).run();
  if(change==='archived')await env.DB.prepare('UPDATE projects SET archived_at=? WHERE id=?').bind(Date.now(),s.p).run();
  controller.enqueue(new TextEncoder().encode(JSON.stringify(operation(1))));controller.close();await expect(result).rejects.toMatchObject({status:409,code:'job_conflict'});
  expect(await env.DB.prepare('SELECT status,version FROM generation_jobs WHERE project_id=?').bind(s.p).first()).toEqual({status:'queued',version:1});expect((await env.DB.prepare('SELECT COUNT(*) n FROM generation_job_operations').first<any>()).n).toBe(0);
 });
});
