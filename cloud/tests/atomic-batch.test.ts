import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, evictDurableObject, reset, runInDurableObject } from 'cloudflare:test';
import type { Env } from '../src/types';
import { sha256 } from '../src/http';

const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[]},app=(exports as any).default;
beforeEach(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
afterEach(async()=>{vi.restoreAllMocks();await reset();});
async function user(uid=crypto.randomUUID()){
  const token=crypto.randomUUID(),sid=crypto.randomUUID();await env.DB.prepare('INSERT OR IGNORE INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(uid,uid,'Writer',Date.now()).run();
  await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(await sha256(token),sid,uid,'Mac',Date.now(),Date.now()+86400000).run();return{uid,token,sid};
}
async function call(path:string,token:string,method='GET',payload?:unknown){const r=await app.fetch(`https://scriv.test${path}`,{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:payload===undefined?undefined:JSON.stringify(payload)});return{status:r.status,data:await r.json<any>()};}
const scene={id:'scene',kind:'scene',data:{id:'scene',title:'Long scene',order:0}};
function entry(duration=2000){return{id:'entry',kind:'entry',data:{id:'entry',sceneId:'scene',order:0,kind:'dialogue',text:'Hello',ownedDurationMs:duration,coverageDurationMs:0,color:'blue',words:[{id:'word',text:'Hello',startMs:0,endMs:duration}]}};}
const cue=(index:number,scale=1)=>({id:`cue-${String(index).padStart(5,'0')}`,kind:'cue',data:{id:`cue-${String(index).padStart(5,'0')}`,sceneId:'scene',label:'Frame',prompt:'',startMs:index*10*scale,endMs:(index+1)*10*scale}});
const put=(item:any,expectedVersion=1,lease?:any)=>({op:'put',...item,expectedVersion,...(lease?{lease:{token:lease.token,fence:lease.fence}}:{})});
async function setup(count=200){const owner=await user(),project=(await call('/v1/projects',owner.token,'POST',{title:'Film'})).data.project.id,path=`/v1/projects/${project}`;const seeded=await call(`${path}/import`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:0,items:[scene,entry(count*10),...Array.from({length:count},(_,i)=>cue(i))]});expect(seeded.status).toBe(200);return{owner,project,path,count};}
async function plan(operations:unknown[],extra:Record<string,unknown>={}){const contents:string[]=[];for(let i=0;i<operations.length;i+=100)contents.push(JSON.stringify(operations.slice(i,i+100)));const parts=await Promise.all(contents.map(async(content)=>({hash:await sha256(content),bytes:new TextEncoder().encode(content).byteLength,count:JSON.parse(content).length})));return{manifest:{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:1,label:'Resize long scene',operationCount:operations.length,parts,...extra},contents};}
async function upload(path:string,token:string,batch:Awaited<ReturnType<typeof plan>>){expect((await call(`${path}/batches`,token,'POST',batch.manifest)).status).toBe(200);for(const [i,content] of batch.contents.entries())expect((await call(`${path}/batches/${batch.manifest.commandId}/parts/${i}`,token,'PUT',{content})).status).toBe(200);}
async function commit(path:string,token:string,batch:Awaited<ReturnType<typeof plan>>){return call(`${path}/batches/${batch.manifest.commandId}/commit`,token,'POST',batch.manifest);}
const resize=(count:number)=>[put(entry(count*20)),...Array.from({length:count},(_,i)=>put(cue(i,2)))];
async function stats(project:string){return runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),(_instance,state)=>({batches:state.storage.sql.exec('SELECT COUNT(*) n FROM command_batches').one().n,parts:state.storage.sql.exec('SELECT COUNT(*) n FROM command_batch_parts').one().n,changes:state.storage.sql.exec('SELECT COUNT(*) n FROM changes WHERE seq=2').one().n}));}

describe('bounded atomic structural edits',()=>{
  it('resumes a 1,001-item resize after eviction and creates one history event and idempotent receipt',async()=>{
    const {owner,path,project,count}=await setup(1000),batch=await plan(resize(count));
    expect((await call(`${path}/batches`,owner.token,'POST',batch.manifest)).status).toBe(200);
    const first=`${path}/batches/${batch.manifest.commandId}/parts/0`;
    expect((await call(first,owner.token,'PUT',{content:batch.contents[0]})).status).toBe(200);
    expect((await call(first,owner.token,'PUT',{content:batch.contents[0]})).status).toBe(200);
    expect((await commit(path,owner.token,batch)).data.error.code).toBe('batch_incomplete');
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(1);
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    await upload(path,owner.token,batch);const accepted=await commit(path,owner.token,batch);expect(accepted.status).toBe(200);expect(accepted.data).toMatchObject({seq:2,timingVersion:2,snapshotRequired:true,items:[]});
    expect((await commit(path,owner.token,batch)).data).toEqual(accepted.data);expect((await call(`${path}/batches`,owner.token,'POST',batch.manifest)).data).toEqual(accepted.data);
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.headSeq).toBe(2);expect(snapshot.items.find((i:any)=>i.id==='entry').data.ownedDurationMs).toBe(20000);expect(snapshot.items.find((i:any)=>i.id===cue(999).id).data.endMs).toBe(20000);expect(snapshot.leases).toEqual([]);
    expect(await stats(project)).toEqual({batches:0,parts:0,changes:1001});
    const history=(await call(`${path}/snapshot?seq=1`,owner.token)).data;expect(history.items).toHaveLength(200);
    const tail=(await call(`${path}/snapshot?seq=1&after=cue-99999`,owner.token)).data;expect(tail.items.find((i:any)=>i.id==='entry').data.ownedDurationMs).toBe(10000);
    const events=(await call(`${path}/events?after=1`,owner.token)).data.events;expect(events).toHaveLength(1);expect(events[0].data.snapshotRequired).toBe(true);
    expect((await call(`${path}/batches`,owner.token,'POST',{...batch.manifest,label:'Not the same edit'})).data.error.code).toBe('command_reused');
  });
  it('deletes a 202-item scene in one transaction with full before/after history and no held structural leases',async()=>{
    const {owner,path,project,count}=await setup(),batch=await plan([scene,entry(),...Array.from({length:count},(_,i)=>cue(i))].map(item=>({op:'delete',id:item.id,expectedVersion:1})),{label:'Delete scene'});
    await upload(path,owner.token,batch);expect((await commit(path,owner.token,batch)).status).toBe(200);
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.items).toEqual([]);expect(snapshot.deletedItems).toHaveLength(202);expect(snapshot.headSeq).toBe(2);expect(snapshot.leases).toEqual([]);expect((await stats(project)).changes).toBe(202);
    const historical=(await call(`${path}/snapshot?seq=1&after=cue-99999`,owner.token)).data;expect(historical.items.map((i:any)=>i.id)).toContain('scene');expect(historical.items.find((i:any)=>i.id==='entry').data.text).toBe('Hello');
  });
  it('rolls back all changed items and temporary leases when the final item is locked, preserving the UI lease',async()=>{
    const {owner,path,project,count}=await setup();const ui=(await call(`${path}/leases`,owner.token,'POST',{itemId:'entry',sessionId:'editor'})).data;
    const other=(await call(`${path}/leases`,owner.token,'POST',{itemId:cue(199).id,sessionId:'other-editor'})).data;
    const operations=resize(count);operations[0]=put(entry(count*20),1,ui);const batch=await plan(operations);await upload(path,owner.token,batch);
    const failed=await commit(path,owner.token,batch);expect(failed.data.error.code).toBe('item_locked');const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.headSeq).toBe(1);expect(snapshot.items.every((i:any)=>i.version===1)).toBe(true);expect(snapshot.leases).toHaveLength(2);expect(await stats(project)).toEqual({batches:0,parts:0,changes:0});
    expect((await call(`${path}/leases`,owner.token,'DELETE',{itemId:other.itemId,sessionId:'other-editor',epoch:1,token:other.token,fence:other.fence})).status).toBe(200);
    await upload(path,owner.token,batch);expect((await commit(path,owner.token,batch)).status).toBe(200);const leases=(await call(`${path}/leases`,owner.token)).data.leases;expect(leases).toHaveLength(1);expect(leases[0]).toMatchObject({itemId:'entry',fence:ui.fence});
  });
  it('retains timing, expected-item-version and explicit stale-lease fences without partial writes',async()=>{
    const {owner,path,count}=await setup();for(const test of ['timing','version','lease']){
      const operations=resize(count);if(test==='version')operations[count]!.expectedVersion=0;if(test==='lease')operations[0]=put(entry(count*20),1,{token:'stale-token',fence:1});
      const batch=await plan(operations,test==='timing'?{expectedTimingVersion:0}:{});await upload(path,owner.token,batch);const result=await commit(path,owner.token,batch);
      expect(result.data.error.code).toBe(test==='timing'?'timing_conflict':test==='version'?'version_conflict':'lease_required');const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.headSeq).toBe(1);expect(snapshot.leases).toEqual([]);
    }
  });
  it('rejects mutated/missing parts, cross-session uploads, duplicate operations and oversized manifests',async()=>{
    const {owner,path,project}=await setup(),other=await user(owner.uid),batch=await plan(resize(200));await upload(path,owner.token,batch);
    const part=`${path}/batches/${batch.manifest.commandId}/parts/0`;
    expect((await call(part,other.token,'PUT',{content:batch.contents[0]})).data.error.code).toBe('batch_session_changed');
    expect((await call(part,owner.token,'PUT',{content:batch.contents[0]+' '})).data.error.code).toBe('batch_part_mismatch');
    expect((await call(`${path}/batches`,other.token,'POST',batch.manifest)).data.error.code).toBe('batch_session_changed');expect((await stats(project)).batches).toBe(0);
    const duplicate=await plan([...resize(200),put(entry(4000))]);await upload(path,owner.token,duplicate);expect((await commit(path,owner.token,duplicate)).data.error.code).toBe('duplicate_operation');
    expect((await call(`${path}/batches`,owner.token,'POST',{...batch.manifest,operationCount:10001})).status).toBe(400);
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(1);
  });
  it('expires abandoned upload bytes without touching project history',async()=>{
    const {owner,path,project}=await setup(),batch=await plan(resize(200));await upload(path,owner.token,batch);
    await runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),async(instance:any,state)=>{state.storage.sql.exec('UPDATE command_batches SET expires_at=0');await instance.alarm();});
    expect(await stats(project)).toEqual({batches:0,parts:0,changes:0});await upload(path,owner.token,batch);expect((await commit(path,owner.token,batch)).status).toBe(200);
  });
  it('fences a delayed commit after logout, but the same signed-in account can reconcile a fresh batch',async()=>{
    const {owner,path,project}=await setup(),other=await user(owner.uid),batch=await plan(resize(200));await upload(path,owner.token,batch);
    const stub=env.PROJECTS.get(env.PROJECTS.idFromName(project));await runInDurableObject(stub,(instance:any)=>{const state=instance.state.bind(instance);instance.entered=false;instance.state=()=>{instance.entered=true;return state();};});
    let controller!:ReadableStreamDefaultController<Uint8Array>;const stream=new ReadableStream<Uint8Array>({start(c){controller=c;}});
    const pending=app.fetch(`https://scriv.test${path}/batches/${batch.manifest.commandId}/commit`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json'},body:stream});
    await vi.waitFor(async()=>expect(await runInDurableObject(stub,(instance:any)=>instance.entered)).toBe(true));
    expect((await call('/auth/logout',owner.token,'POST')).status).toBe(200);controller.enqueue(new TextEncoder().encode(JSON.stringify(batch.manifest)));controller.close();expect((await (await pending).json<any>()).error.code).toBe('access_changed');
    expect((await call(`${path}/snapshot`,other.token)).data.headSeq).toBe(1);expect((await call(`${path}/batches`,other.token,'POST',batch.manifest)).data.error.code).toBe('batch_session_changed');
    const reconciled=await plan(resize(200),{sessionId:'new-editor'});await upload(path,other.token,reconciled);expect((await commit(path,other.token,reconciled)).status).toBe(200);
  });
});

describe('atomic source-anchor and character-link graph compatibility',()=>{
  it('allows overlapping source-owned coverage but rejects unresolved/missing source entries atomically',async()=>{
    const {owner,path}=await setup(1);
    const anchored=(id:string,offset:number,duration:number)=>({id,kind:'cue',data:{id,sceneId:'scene',label:id,prompt:'',startMs:offset,endMs:Math.min(10,offset+duration),startAnchor:{entryId:'entry',offsetMs:offset},authoredDurationMs:duration}});
    const a=anchored('anchored-a',0,20),b=anchored('anchored-b',5,4);
    const batch=await plan([{op:'delete',id:cue(0).id,expectedVersion:1},put(a,0),put(b,0)]);await upload(path,owner.token,batch);expect((await commit(path,owner.token,batch)).status).toBe(200);
    const stripped={...a,data:{id:a.id,sceneId:'scene',label:a.id,prompt:'',startMs:0,endMs:10}},stripBatch=await plan([put(stripped)],{expectedTimingVersion:2});
    await upload(path,owner.token,stripBatch);expect((await commit(path,owner.token,stripBatch)).data.error.code).toBe('schema_upgrade_required');
    const wrong=structuredClone(a);wrong.data.startAnchor.offsetMs=3;
    for(const operations of [[put(wrong)],[{op:'delete',id:'entry',expectedVersion:1}]]){
      const invalid=await plan(operations,{expectedTimingVersion:2});await upload(path,owner.token,invalid);expect(['cue_anchor','cue_timing']).toContain((await commit(path,owner.token,invalid)).data.error.code);expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(2);
    }
  });
  it('preserves mention identity references and permits explicit unlink plus character deletion in the same edit',async()=>{
    const {owner,path}=await setup(1),character={id:'character',kind:'character',data:{id:'character',name:'Hello',aliases:[],biography:'',appearance:'',color:'blue'}};
    const linked={...entry(10),data:{...entry(10).data,characterLinks:[{id:'link',characterId:'character',location:0,length:5,text:'Hello',isConfirmed:false}]}};
    const add=await plan([put(character,0),put(linked)]);await upload(path,owner.token,add);expect((await commit(path,owner.token,add)).status).toBe(200);
    const stripLinks=await plan([put(entry(10),2)]);await upload(path,owner.token,stripLinks);expect((await commit(path,owner.token,stripLinks)).data.error.code).toBe('schema_upgrade_required');
    const remove={op:'delete',id:'character',expectedVersion:1},blocked=await plan([remove]);await upload(path,owner.token,blocked);expect((await commit(path,owner.token,blocked)).data.error.code).toBe('item_in_use');
    const unlinked={...linked,data:{...linked.data,characterLinks:[{id:'link',location:0,length:5,text:'Hello',isConfirmed:true}]}};
    const removeTogether=await plan([remove,put(unlinked,2)]);await upload(path,owner.token,removeTogether);expect((await commit(path,owner.token,removeTogether)).status).toBe(200);
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.items.some((i:any)=>i.id==='character')).toBe(false);expect(snapshot.items.find((i:any)=>i.id==='entry').data.characterLinks[0].characterId).toBeUndefined();
  });
});

describe('authored word provenance compatibility fence',()=>{
  it('refuses silent authored-marker stripping but permits intentional removal of the source word identity',async()=>{
    const {owner,path}=await setup(1),authored=entry(10) as any;authored.data.words[0].timingSource='authored';
    const add=await plan([put(authored)]);await upload(path,owner.token,add);expect((await commit(path,owner.token,add)).status).toBe(200);
    const strip=await plan([put(entry(10),2)],{expectedTimingVersion:2});await upload(path,owner.token,strip);expect((await commit(path,owner.token,strip)).data.error.code).toBe('schema_upgrade_required');
    const replaced=entry(10);replaced.data.words[0]!.id='new-word';const replace=await plan([put(replaced,2)],{expectedTimingVersion:2});await upload(path,owner.token,replace);expect((await commit(path,owner.token,replace)).status).toBe(200);
  });
});

describe('atomic retry authorization and zero-owned source rules',()=>{
  it('returns an accepted receipt after a writer becomes read-only but rejects a fresh batch',async()=>{
    const {owner,path,project}=await setup(),member=await user(),team=(await call('/v1/teams',owner.token,'POST',{name:'Team'})).data.team.id;
    await env.DB.prepare("UPDATE teams SET subscription_status='active',paid_until=?,current_period_end=? WHERE id=?").bind(Date.now()+86400000,Date.now()+86400000,team).run();
    await env.DB.prepare('UPDATE projects SET team_id=? WHERE id=?').bind(team,project).run();await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team,member.uid,Date.now()).run();
    const batch=await plan(resize(200));await upload(path,member.token,batch);const accepted=await commit(path,member.token,batch);expect(accepted.status).toBe(200);
    expect((await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'PATCH',{role:'viewer'})).status).toBe(200);
    expect((await commit(path,member.token,batch)).data).toEqual(accepted.data);expect((await call(`${path}/batches`,member.token,'POST',batch.manifest)).data).toEqual(accepted.data);
    expect((await call(`${path}/batches`,member.token,'POST',{...batch.manifest,commandId:crypto.randomUUID()})).status).toBe(403);expect((await call(`${path}/snapshot`,member.token)).data.headSeq).toBe(2);
  });
  it('retains a zero-owned direction as an image source and does not silently assign its cue to the next entry',async()=>{
    const {owner,path}=await setup(1),direction={id:'direction',kind:'entry',data:{id:'direction',sceneId:'scene',order:-1,kind:'direction',text:'Look left.',ownedDurationMs:0,coverageDurationMs:10,color:'blue',words:[]}},anchored={id:'anchored',kind:'cue',data:{id:'anchored',sceneId:'scene',label:'Action',prompt:'',startMs:0,endMs:10,startAnchor:{entryId:'direction',offsetMs:0},authoredDurationMs:20}};
    const add=await plan([{op:'delete',id:cue(0).id,expectedVersion:1},put(direction,0),put(anchored,0)]);await upload(path,owner.token,add);expect((await commit(path,owner.token,add)).status).toBe(200);
    const remove=await plan([{op:'delete',id:'direction',expectedVersion:1}],{expectedTimingVersion:2});await upload(path,owner.token,remove);expect((await commit(path,owner.token,remove)).data.error.code).toBe('cue_anchor');
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.items.find((i:any)=>i.id==='anchored').data.startAnchor.entryId).toBe('direction');expect(snapshot.headSeq).toBe(2);
  });
});

describe('dormant source-owned tail coverage',()=>{
  it('retains positive authored duration at a zero-owned scene tail and revives it when following content arrives',async()=>{
    const {owner,path}=await setup(1),direction={id:'tail',kind:'entry',data:{id:'tail',sceneId:'scene',order:0,kind:'direction',text:'Hold.',ownedDurationMs:0,coverageDurationMs:20,color:'blue',words:[]}},dormant={id:'dormant',kind:'cue',data:{id:'dormant',sceneId:'scene',label:'Hold frame',prompt:'',startMs:0,endMs:0,startAnchor:{entryId:'tail',offsetMs:0},authoredDurationMs:20}};
    const empty=await plan([{op:'delete',id:'entry',expectedVersion:1},{op:'delete',id:cue(0).id,expectedVersion:1},put(direction,0),put(dormant,0)]);await upload(path,owner.token,empty);expect((await commit(path,owner.token,empty)).status).toBe(200);
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.items.find((i:any)=>i.id==='dormant').data).toMatchObject({startMs:0,endMs:0,authoredDurationMs:20});
    const following=entry(10);following.id='following';following.data.id='following';following.data.order=1;
    const visible={...dormant,data:{...dormant.data,endMs:10}},revive=await plan([put(following,0),put(visible)],{expectedTimingVersion:2});await upload(path,owner.token,revive);expect((await commit(path,owner.token,revive)).status).toBe(200);
    const invalid=await plan([put(dormant,2)],{expectedTimingVersion:3});await upload(path,owner.token,invalid);expect((await commit(path,owner.token,invalid)).data.error.code).toBe('cue_anchor');
    expect((await call(`${path}/snapshot`,owner.token)).data.items.find((i:any)=>i.id==='dormant').data).toMatchObject({startMs:0,endMs:10,authoredDurationMs:20});
  });
});
