import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, evictDurableObject, reset, runInDurableObject } from 'cloudflare:test';
import type { Env } from '../src/types';
import { sha256 } from '../src/http';

const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[]};
const app=(exports as any).default;
const sockets:WebSocket[]=[];
beforeEach(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
afterEach(async()=>{for(const socket of sockets.splice(0))socket.close();vi.restoreAllMocks();await reset();});
async function user(name='Writer',uid=crypto.randomUUID()){
  const token=crypto.randomUUID(),sid=crypto.randomUUID();
  await env.DB.prepare('INSERT OR IGNORE INTO users(id,github_id,name,created_at)VALUES(?,?,?,?)').bind(uid,uid,name,Date.now()).run();
  await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)VALUES(?,?,?,?,?,?)').bind(await sha256(token),sid,uid,'Mac',Date.now(),Date.now()+86400000).run();
  return{uid,token,sid};
}
async function call(path:string,token:string,method='GET',payload?:unknown){
  const response=await app.fetch(`https://scriv.test${path}`,{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:payload===undefined?undefined:JSON.stringify(payload)});
  return{status:response.status,data:await response.json<any>()};
}
async function setup(paid=false){
  const owner=await user();let team:string|undefined;
  if(paid){team=(await call('/v1/teams',owner.token,'POST',{name:'Film team'})).data.team.id;await env.DB.prepare("UPDATE teams SET subscription_status='active',paid_until=?,current_period_end=? WHERE id=?").bind(Date.now()+86400000,Date.now()+86400000,team!).run();}
  const project=(await call('/v1/projects',owner.token,'POST',{title:'Film',...(team?{teamId:team}:{})})).data.project.id as string;
  const path=`/v1/projects/${project}`;
  const seed=await call(`${path}/commands`,owner.token,'POST',command([put(scene()),put(entry())]));expect(seed.status).toBe(200);
  return{owner,team,project,path};
}
const scene=(id='scene')=>({id,kind:'scene',data:{id,title:'Scene',order:0}});
const entry=(id='entry',wordId=`${id}-word`)=>({id,kind:'entry',data:{id,sceneId:'scene',order:0,kind:'dialogue',text:'Hello',ownedDurationMs:1000,coverageDurationMs:0,color:'blue',words:[{id:wordId,text:'Hello',startMs:0,endMs:1000}]}});
const image=(id='image')=>({id,kind:'image',data:{id,version:1,fileName:`${id}.png`,sha256:'a'.repeat(64),mimeType:'image/png',byteCount:100,characterIds:[] as string[],prompt:'',createdAt:1000}});
const command=(operations:unknown[],extra:Record<string,unknown>={})=>({commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:0,label:'Edit',operations,...extra});
const put=(item:any,expectedVersion=0,lease?:any)=>({op:'put',...item,expectedVersion,...(lease?{lease:{token:lease.token,fence:lease.fence}}:{})});
async function claim(path:string,token:string,itemId='entry',sessionId='editor'){const response=await call(`${path}/leases`,token,'POST',{itemId,sessionId});expect(response.status).toBe(200);return response.data;}
function waitMessage(socket:WebSocket,predicate:(value:any)=>boolean){return new Promise<any>((resolve,reject)=>{const timer=setTimeout(()=>{socket.removeEventListener('message',handler);reject(Error('socket message timeout'));},5000);const handler=(event:MessageEvent)=>{const value=JSON.parse(String(event.data));if(predicate(value)){clearTimeout(timer);socket.removeEventListener('message',handler);resolve(value);}};socket.addEventListener('message',handler);});}
async function connect(path:string,token:string){const response=await app.fetch(`https://scriv.test${path}/socket`,{headers:{authorization:`Bearer ${token}`,upgrade:'websocket'}});expect(response.status).toBe(101);const socket=response.webSocket!;sockets.push(socket);const hello=waitMessage(socket,v=>v.type==='hello');socket.accept();await hello;return socket;}

describe('durable discussion and reconnect',()=>{
  it('journals chat and resolution atomically and repairs them after eviction without replay duplicates',async()=>{
    const {owner,path,project}=await setup();
    const thread=(await call(`${path}/threads`,owner.token,'POST',{itemId:'entry'})).data.thread;
    const payload={id:'message-1',body:'Keep the pause.',attachments:[{itemId:'entry'}]};
    const posted=await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload);expect(posted.status).toBe(201);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload)).data).toEqual(posted.data);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{...payload,body:'Different'})).status).toBe(409);
    await call(`${path}/threads/${thread.id}`,owner.token,'PATCH',{resolved:true});
    await call(`${path}/threads/${thread.id}`,owner.token,'PATCH',{resolved:true});
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    const replay=(await call(`${path}/events?after=1`,owner.token)).data;
    expect(replay.events.map((event:any)=>event.kind)).toEqual(['discussion.thread-created','discussion.message-created','discussion.thread-updated']);
    expect(replay.events.map((event:any)=>event.seq)).toEqual([2,3,4]);
    expect(replay.events.every((event:any)=>event.changes.length===0&&event.data.timingVersion===1)).toBe(true);
    expect(replay.events[1].data.message).toEqual(posted.data.message);expect(replay.events[2].data.thread.resolved).toBe(true);
    const restored=await call(`${path}/restore`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,seq:0});expect(restored.status).toBe(200);
    expect((await call(`${path}/snapshot`,owner.token)).data.items).toHaveLength(0);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token)).data.messages).toHaveLength(1);
    expect((await call(`${path}/threads/${thread.id}`,owner.token)).data.thread.resolved).toBe(true);
  });
  it('delivers chat through the durable replay stream before a watermark',async()=>{
    const {owner,path}=await setup(true),socket=await connect(path,owner.token),received:any[]=[];
    socket.addEventListener('message',(event:MessageEvent)=>{const value=JSON.parse(String(event.data));if(value.type==='events')received.push(...value.events);});
    const thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread;
    await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:'message',body:'Offline readers must see this.'});
    const watermark=waitMessage(socket,v=>v.type==='watermark');socket.send(JSON.stringify({type:'ping'}));expect((await watermark).headSeq).toBe(3);
    expect(received.map(event=>event.seq)).toEqual([2,3]);expect(received[1].data.message.body).toContain('Offline');
    const replay=waitMessage(socket,v=>v.type==='events');socket.send(JSON.stringify({type:'resume',after:1}));expect((await replay).events.map((event:any)=>event.seq)).toEqual([2,3]);
  });
  it('recovers an accepted send after the attachment disappears and the member becomes read-only',async()=>{
    const {owner,path,team}=await setup(true),member=await user('Member');
    await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const thread=(await call(`${path}/threads`,member.token,'POST',{itemId:'entry'})).data.thread,payload={id:'message',body:'Saved already.',attachments:[{itemId:'entry'}]};
    const accepted=await call(`${path}/threads/${thread.id}/messages`,member.token,'POST',payload);expect(accepted.status).toBe(201);
    const lease=await claim(path,owner.token);expect((await call(`${path}/commands`,owner.token,'POST',command([{op:'delete',id:'entry',expectedVersion:1,lease}],{expectedTimingVersion:1}))).status).toBe(200);
    await env.DB.prepare("UPDATE teams SET subscription_status='canceled',canceled_at=? WHERE id=?").bind(Date.now(),team!).run();
    expect((await call(`${path}/threads`,member.token,'POST',{itemId:'entry'})).data.thread.id).toBe(thread.id);
    expect((await call(`${path}/threads/${thread.id}/messages`,member.token,'POST',payload)).data).toEqual(accepted.data);
    expect((await call(`${path}/threads/${thread.id}/messages`,member.token,'POST',{...payload,id:'new'})).status).toBe(403);
  });
  it('rejects fresh references to deleted attachments but preserves historical discussion',async()=>{
    const {owner,path}=await setup(),thread=(await call(`${path}/threads`,owner.token,'POST',{itemId:'entry'})).data.thread,lease=await claim(path,owner.token);
    await call(`${path}/commands`,owner.token,'POST',command([{op:'delete',id:'entry',expectedVersion:1,lease}],{expectedTimingVersion:1}));
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:'bad',body:'Attachment',attachments:[{itemId:'entry'}]})).status).toBe(404);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:'good',body:'Discuss the removed line.'})).status).toBe(201);
  });
  it('keeps pagination monotonic when the clock repeats or moves backward',async()=>{
    const {owner,path,project}=await setup(),thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread;
    const at=Date.now()+100000;
    await runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),(_instance,state)=>{state.storage.sql.exec('INSERT INTO messages(id,thread_id,user_id,name,body,attachments,at) VALUES(?,?,?,?,?,?,?)','z-message',thread.id,owner.uid,'Writer','First','[]',at);});
    const posted=await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:'a-message',body:'Second'});expect(posted.data.message.at).toBe(at+1);
    const next=(await call(`${path}/threads/${thread.id}/messages?after=${at}&afterId=z-message`,owner.token)).data;
    expect(next.messages.map((message:any)=>message.id)).toEqual(['a-message']);
  });
  it('serializes concurrent canonical thread creation and identical sends exactly once',async()=>{
    const {owner,path}=await setup();
    const threads=await Promise.all(Array.from({length:8},()=>call(`${path}/threads`,owner.token,'POST',{itemId:'entry'})));
    expect(new Set(threads.map(result=>result.data.thread.id)).size).toBe(1);expect(threads.filter(result=>result.status===201)).toHaveLength(1);
    const thread=threads[0]!.data.thread,payload={id:'concurrent-message',body:'Only one accepted send.'};
    const sends=await Promise.all(Array.from({length:8},()=>call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload)));
    expect(sends.filter(result=>result.status===201)).toHaveLength(1);expect(sends.every(result=>result.status===200||result.status===201)).toBe(true);
    expect((await call(`${path}/events?after=1`,owner.token)).data.events.map((event:any)=>event.kind)).toEqual(['discussion.thread-created','discussion.message-created']);
  });
  it('rejects invalid initial anchors without creating a thread or advancing history',async()=>{
    const {owner,path}=await setup();
    for(const anchor of [{wordIds:['missing']},{wordIds:['entry-word','entry-word']},{imageVersionId:'missing'}])expect((await call(`${path}/threads`,owner.token,'POST',{itemId:'entry',anchor})).data.error.code).toBe('invalid_anchor');
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(1);
    const initial=await call(`${path}/threads`,owner.token,'POST',{itemId:'entry',anchor:{wordIds:['entry-word']}});expect(initial.status).toBe(201);
    const reopened=await call(`${path}/threads`,owner.token,'POST',{itemId:'entry',anchor:{wordIds:[]}});expect(reopened.data.thread.anchor).toEqual({wordIds:['entry-word']});
  });
  it('allows atomic initial import after a project discussion has started',async()=>{
    const owner=await user(),project=(await call('/v1/projects',owner.token,'POST',{title:'Empty film'})).data.project.id,path=`/v1/projects/${project}`;
    await call(`${path}/threads`,owner.token,'POST',{});
    const imported=await call(`${path}/import`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:0,items:[scene(),entry()]});expect(imported.status).toBe(200);expect(imported.data.seq).toBe(2);
  });
});

describe('native WebSocket transport and presence',()=>{
  it('accepts binary UTF-8 resume, ping and presence from URLSession clients',async()=>{
    const {owner,path}=await setup(true),socket=await connect(path,owner.token);
    const replay=waitMessage(socket,v=>v.type==='events');socket.send(new TextEncoder().encode(JSON.stringify({type:'resume',after:0})));expect((await replay).events[0].seq).toBe(1);
    const presence=waitMessage(socket,v=>v.type==='presence'&&v.peers.some((peer:any)=>peer.itemId==='entry'));
    socket.send(new TextEncoder().encode(JSON.stringify({type:'presence',itemId:'entry',selection:{start:0,end:3},cursor:{x:12,y:7}})));
    expect((await presence).peers[0]).toMatchObject({userId:owner.uid,selection:{start:0,end:3},cursor:{x:12,y:7}});
    const watermark=waitMessage(socket,v=>v.type==='watermark');socket.send(new TextEncoder().encode('{"type":"ping"}'));expect((await watermark).headSeq).toBe(1);
  });
  it('rejects oversized UTF-8, invalid binary and malformed presence without losing valid access',async()=>{
    const {owner,path}=await setup(true),socket=await connect(path,owner.token);
    for(const [payload,code] of [[JSON.stringify({type:'presence',unused:'🙂'.repeat(17000)}),'message_too_large'],[new Uint8Array([0xff]),'invalid_json'],[JSON.stringify({type:'presence',itemId:'deleted'}),'invalid_presence'],[JSON.stringify({type:'presence',itemId:'entry',selection:{start:9,end:2}}),'invalid_field']] as const){
      const error=waitMessage(socket,v=>v.type==='error');socket.send(payload);expect((await error).error.code).toBe(code);
    }
    const watermark=waitMessage(socket,v=>v.type==='watermark');socket.send('{"type":"ping"}');expect((await watermark).headSeq).toBe(1);
  });
  it('does not close a sender when a peer disappears during signaling',async()=>{
    const {owner,path}=await setup(true),socket=await connect(path,owner.token),error=waitMessage(socket,v=>v.type==='error');
    socket.send(JSON.stringify({type:'signal',signalType:'offer',toDeviceId:'missing',payload:{sdp:'test'}}));expect((await error).error.code).toBe('peer_unavailable');
    const watermark=waitMessage(socket,v=>v.type==='watermark');socket.send('{"type":"ping"}');expect((await watermark).headSeq).toBe(1);
  });
});

async function slowAuthorizedPost(project:string,path:string,token:string,payload:unknown){
  const stub=env.PROJECTS.get(env.PROJECTS.idFromName(project));
  let controller!:ReadableStreamDefaultController<Uint8Array>;
  await runInDurableObject(stub,(instance:any)=>{
    const state=instance.state.bind(instance);instance.testAuthorizedBodyEntered=false;
    // Plain object state may cross test contexts; resolving a test-owned I/O
    // promise from a Durable Object is deliberately forbidden by workerd.
    instance.state=()=>{instance.testAuthorizedBodyEntered=true;return state();};
  });
  const stream=new ReadableStream<Uint8Array>({start(value){controller=value;}});
  const pending=app.fetch(`https://scriv.test${path}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:stream});
  try{await vi.waitFor(async()=>{expect(await runInDurableObject(stub,(instance:any)=>instance.testAuthorizedBodyEntered)).toBe(true);},{timeout:5000,interval:10});}
  catch(error){controller.close();await pending;throw error;}
  return{finish:async()=>{controller.enqueue(new TextEncoder().encode(JSON.stringify(payload)));controller.close();const response=await pending;return{status:response.status,data:await response.json<any>()};}};
}

describe('authorization changes during an in-flight request',()=>{
  it('cannot create a new item from a slow body after member removal has completed',async()=>{
    const {owner,path,project,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const delayed=await slowAuthorizedPost(project,`${path}/commands`,member.token,command([put(scene('unauthorized-new-scene'))]));
    expect((await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'DELETE')).status).toBe(200);
    const result=await delayed.finish();expect(result.status).toBe(409);expect(result.data.error.code).toBe('access_changed');
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;expect(snapshot.headSeq).toBe(1);expect(snapshot.items.some((item:any)=>item.id==='unauthorized-new-scene')).toBe(false);
  });
  it('cannot acquire an edit lease from a slow body after a viewer downgrade',async()=>{
    const {owner,path,project,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const delayed=await slowAuthorizedPost(project,`${path}/leases`,member.token,{itemId:'entry',sessionId:'editor'});
    expect((await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'PATCH',{role:'viewer'})).status).toBe(200);
    expect((await delayed.finish()).data.error.code).toBe('access_changed');expect((await call(`${path}/leases`,owner.token)).data.leases).toHaveLength(0);
  });
  it('cannot append chat or recover a cached message through a revoked session',async()=>{
    for(const replay of [false,true]){
      const {owner,path,project}=await setup(),other=await user('Writer',owner.uid),thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread,payload={id:'message',body:'Private saved text.'};
      if(replay)expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload)).status).toBe(201);
      const delayed=await slowAuthorizedPost(project,`${path}/threads/${thread.id}/messages`,owner.token,payload);
      expect((await call('/auth/logout',owner.token,'POST')).status).toBe(200);
      const result=await delayed.finish();expect(result.data.error.code).toBe('access_changed');expect(result.data.message).toBeUndefined();
      expect((await call(`${path}/threads/${thread.id}/messages`,other.token)).data.messages).toHaveLength(replay?1:0);
    }
  });
  it('recovers the original receipt after a fenced retry without duplicating its prior commit',async()=>{
    const {owner,path,project,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const payload=command([put(scene('accepted-before-fence'))]);
    const accepted=await call(`${path}/commands`,owner.token,'POST',payload);expect(accepted.status).toBe(200);
    const delayed=await slowAuthorizedPost(project,`${path}/commands`,owner.token,payload);
    await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'DELETE');expect((await delayed.finish()).data.error.code).toBe('access_changed');
    expect((await call(`${path}/commands`,owner.token,'POST',payload)).data).toEqual(accepted.data);
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(2);
  });
  it('can retry an uncommitted fenced request after fresh authorization',async()=>{
    const {owner,path,project,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const payload=command([put(scene('authorized-scene'))]),delayed=await slowAuthorizedPost(project,`${path}/commands`,owner.token,payload);
    await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'DELETE');
    expect((await delayed.finish()).data.error.code).toBe('access_changed');
    expect((await call(`${path}/commands`,owner.token,'POST',payload)).status).toBe(200);
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(2);
  });
});

describe('lease revocation and atomic state invariants',()=>{
  it('grants exactly one lease under concurrent same-account device contention',async()=>{
    const {owner,path}=await setup(),devices=await Promise.all(Array.from({length:8},()=>user('Writer',owner.uid)));
    const claims=await Promise.all(devices.map(device=>call(`${path}/leases`,device.token,'POST',{itemId:'entry',sessionId:'editor'})));
    expect(claims.filter(result=>result.status===200)).toHaveLength(1);expect(claims.filter(result=>result.status===423)).toHaveLength(7);
    const winner=claims.findIndex(result=>result.status===200),lease=claims[winner]!.data;
    expect((await call(`${path}/leases`,devices[winner]!.token,'DELETE',lease)).status).toBe(200);
    const next=await claim(path,owner.token);expect(next.fence).toBe(lease.fence+1);
    expect((await call(`${path}/leases`,devices[winner]!.token,'PUT',lease)).status).toBe(423);
  });
  it('immediately releases a removed member lease even without a live socket',async()=>{
    const {owner,path,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const lease=await claim(path,member.token);expect((await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'DELETE')).status).toBe(200);
    expect((await call(`${path}/leases`,owner.token)).data.leases).toHaveLength(0);expect((await claim(path,owner.token)).fence).toBe(lease.fence+1);
  });
  it('releases viewer-downgraded leases without removing the viewer from discussion',async()=>{
    const {owner,path,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    await claim(path,member.token);await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'PATCH',{role:'viewer'});
    expect((await call(`${path}/leases`,owner.token)).data.leases).toHaveLength(0);expect((await call(`${path}/threads`,member.token,'POST',{})).status).toBe(201);
  });
  it('releases revoked-device leases but keeps another session authorized',async()=>{
    const {owner,path}=await setup(),other=await user('Writer',owner.uid),lease=await claim(path,owner.token);
    expect((await call('/auth/logout',owner.token,'POST')).status).toBe(200);
    expect((await call(`${path}/leases`,other.token)).data.leases).toHaveLength(0);expect((await claim(path,other.token)).fence).toBe(lease.fence+1);
    expect((await call(`${path}/snapshot`,owner.token)).status).toBe(401);
  });
  it('returns only tombstone metadata so a reconnected client can undo a deletion with the correct version',async()=>{
    const {owner,path,project}=await setup(),lease=await claim(path,owner.token);
    expect((await call(`${path}/commands`,owner.token,'POST',command([{op:'delete',id:'entry',expectedVersion:1,lease}],{expectedTimingVersion:1}))).status).toBe(200);
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    const snapshot=(await call(`${path}/snapshot`,owner.token)).data;
    expect(snapshot.items.map((item:any)=>item.id)).toEqual(['scene']);expect(snapshot.canImport).toBe(false);
    expect(snapshot.deletedItems).toEqual([{id:'entry',kind:'entry',version:2,data:{},deleted:true}]);expect(JSON.stringify(snapshot.deletedItems)).not.toContain('Hello');
    await call(`${path}/leases`,owner.token,'DELETE',lease);
    const freshLease=await claim(path,owner.token,'entry','reconnected-editor');
    const undone=await call(`${path}/commands`,owner.token,'POST',command([put(entry(),snapshot.deletedItems[0].version,freshLease)],{epoch:snapshot.epoch,sessionId:'reconnected-editor',expectedTimingVersion:snapshot.timingVersion}));
    expect(undone.status).toBe(200);expect(undone.data.items[0].version).toBe(3);expect(undone.data.items[0].deleted).toBe(false);
    expect((await call(`${path}/snapshot`,owner.token)).data.deletedItems).toEqual([]);
  });
  it('distinguishes new discussion-only rooms from a project restored to empty',async()=>{
    const owner=await user(),project=(await call('/v1/projects',owner.token,'POST',{title:'Empty room'})).data.project.id,path=`/v1/projects/${project}`;
    expect((await call(`${path}/snapshot`,owner.token)).data.canImport).toBe(true);
    await call(`${path}/threads`,owner.token,'POST',{});
    const discussionOnly=(await call(`${path}/snapshot`,owner.token)).data;expect(discussionOnly.headSeq).toBe(1);expect(discussionOnly.canImport).toBe(true);
    expect((await call(`${path}/import`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:0,items:[scene(),entry()]})).status).toBe(200);
    await call(`${path}/restore`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,seq:0});
    const restored=(await call(`${path}/snapshot`,owner.token)).data;expect(restored.items).toEqual([]);expect(restored.canImport).toBe(false);expect(restored.deletedItems).toHaveLength(2);
    const forbidden=await call(`${path}/import`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:restored.epoch,expectedTimingVersion:restored.timingVersion,items:[scene(),entry()]});expect(forbidden.data.error.code).toBe('project_not_empty');
  });
  it('fences resurrection as a geometry change even when the tombstone payload is unchanged',async()=>{
    const {owner,path}=await setup(),lease=await claim(path,owner.token);
    expect((await call(`${path}/commands`,owner.token,'POST',command([{op:'delete',id:'entry',expectedVersion:1,lease}],{expectedTimingVersion:1}))).status).toBe(200);
    const stale=await call(`${path}/commands`,owner.token,'POST',command([put(entry(),2,lease)],{expectedTimingVersion:1}));expect(stale.data.error.code).toBe('timing_conflict');
    const restored=await call(`${path}/commands`,owner.token,'POST',command([put(entry(),2,lease)],{expectedTimingVersion:2}));expect(restored.status).toBe(200);expect(restored.data.timingVersion).toBe(3);
  });
  it('rejects project-wide duplicate words atomically but allows moving IDs inside an atomic batch',async()=>{
    const {owner,path}=await setup();
    const rejected=await call(`${path}/commands`,owner.token,'POST',command([put(entry('second','entry-word'))],{expectedTimingVersion:1}));expect(rejected.status).toBe(400);expect(rejected.data.error.code).toBe('duplicate_word');
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(1);
    const lease=await claim(path,owner.token);
    const accepted=await call(`${path}/commands`,owner.token,'POST',command([put(entry('second','entry-word')),put(entry('entry','new-word'),1,lease)],{expectedTimingVersion:1}));expect(accepted.status).toBe(200);
  });
  it('retains word-owner validation across room eviction and restore',async()=>{
    const {owner,path,project}=await setup();await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    const rejected=await call(`${path}/commands`,owner.token,'POST',command([put(entry('second','entry-word'))],{expectedTimingVersion:1}));expect(rejected.data.error.code).toBe('duplicate_word');
    await call(`${path}/restore`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,seq:0});
    const allowed=await call(`${path}/commands`,owner.token,'POST',command([put(scene('other-scene')),put({...entry('second','entry-word'),data:{...entry('second','entry-word').data,sceneId:'other-scene'}})],{epoch:2,expectedTimingVersion:2}));expect(allowed.status).toBe(200);
  });
  it('backfills word ownership when an existing schema-v1 room is reopened',async()=>{
    const {owner,path,project}=await setup();
    await runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),(_instance,state)=>{state.storage.sql.exec('DELETE FROM schema_migrations WHERE version=2');state.storage.sql.exec('DROP TABLE word_owners');});
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    const rejected=await call(`${path}/commands`,owner.token,'POST',command([put(entry('second','entry-word'))],{expectedTimingVersion:1}));expect(rejected.data.error.code).toBe('duplicate_word');
    expect((await call(`${path}/snapshot`,owner.token)).data.items).toHaveLength(2);
  });
  it('replays a committed restore after the actor loses administrator privileges',async()=>{
    const {owner,path,team}=await setup(true),admin=await user('Admin');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'admin',?)").bind(team!,admin.uid,Date.now()).run();
    const payload={commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,seq:0};
    const restored=await call(`${path}/restore`,admin.token,'POST',payload);expect(restored.status).toBe(200);
    await call(`/v1/teams/${team}/members/${admin.uid}`,owner.token,'PATCH',{role:'viewer'});
    expect((await call(`${path}/restore`,admin.token,'POST',payload)).data).toEqual(restored.data);
    expect((await call(`${path}/restore`,admin.token,'POST',{...payload,commandId:crypto.randomUUID(),epoch:2})).status).toBe(403);
  });
  it('bounds replay pages and turns oversized events into durable snapshot hints',async()=>{
    const {owner,path,project}=await setup(true);
    // Seed accepted journal fixtures directly to exercise response size limits
    // without consuming the per-device HTTP write rate budget.
    await runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),(_instance,state)=>{
      state.storage.transactionSync(()=>{
        for(let seq=2;seq<=6;seq++){
          state.storage.sql.exec('INSERT INTO events VALUES(?,?,?,?,?,?,?)',seq,1,`large-${seq}`,owner.uid,'command',Date.now(),JSON.stringify({label:'Large edit',timingVersion:1}));
          const item={id:`large-${seq}`,kind:'character',version:1,data:{id:`large-${seq}`,padding:'x'.repeat(seq===6?300000:200000)},deleted:false};
          state.storage.sql.exec('INSERT INTO changes VALUES(?,?,?,?)',seq,item.id,null,JSON.stringify(item));
        }
        state.storage.sql.exec('UPDATE meta SET head_seq=6');
      });
    });
    const page=(await call(`${path}/events?after=1&limit=200`,owner.token)).data;expect(page.events).toHaveLength(2);expect(page.hasMore).toBe(true);expect(JSON.stringify(page).length).toBeLessThan(525000);
    const next=(await call(`${path}/events?after=3&limit=200`,owner.token)).data;expect(next.events.map((event:any)=>event.seq)).toEqual([4,5,6]);expect(next.hasMore).toBe(false);expect(next.events[2].data.snapshotRequired).toBe(true);expect(next.events[2].changes).toEqual([]);
    const socket=await connect(path,owner.token),replay=waitMessage(socket,value=>value.type==='events');socket.send('{"type":"resume","after":5}');expect((await replay).events[0].data.snapshotRequired).toBe(true);
    const persisted=await runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),(_instance,state)=>state.storage.sql.exec('SELECT LENGTH(after_json) n FROM changes WHERE seq=6').toArray()[0]);expect(persisted.n).toBeGreaterThan(300000);
  });
  it('preserves image identity and version lineage while permitting metadata edits',async()=>{
    const {owner,path}=await setup(),original=image();expect((await call(`${path}/commands`,owner.token,'POST',command([put(original)]))).status).toBe(200);const lease=await claim(path,owner.token,'image');
    const changed={...original,data:{...original.data,sha256:'b'.repeat(64)}};
    expect((await call(`${path}/commands`,owner.token,'POST',command([put(changed,1,lease)]))).data.error.code).toBe('immutable_image');
    expect((await call(`${path}/commands`,owner.token,'POST',command([put({...original,data:{...original.data,prompt:'Updated notes'}},1,lease)]))).status).toBe(200);
    const cyclic={...image('self'),data:{...image('self').data,previousVersionId:'self'}};
    expect((await call(`${path}/commands`,owner.token,'POST',command([put(cyclic)]))).data.error.code).toBe('image_version');
    const revision={...image('revision'),data:{...image('revision').data,previousVersionId:'image',version:2}};
    expect((await call(`${path}/commands`,owner.token,'POST',command([put(revision)]))).status).toBe(200);
  });
});

describe('JSON request validation',()=>{
  it('returns structured 400 errors for malformed JSON, non-object JSON and invalid UTF-8',async()=>{
    const {owner,path}=await setup();
    for(const payload of ['null','[]','42','"text"','true','{',new Uint8Array([0xff])]){
      const response=await app.fetch(`https://scriv.test${path}/commands`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json'},body:payload});
      expect(response.status).toBe(400);expect((await response.json<any>()).error.code).toMatch(/invalid_(field|json)/);
    }
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(1);
  });
  it('enforces the byte limit even without a Content-Length header',async()=>{
    const {owner,path}=await setup(),payload=JSON.stringify({padding:'🙂'.repeat(140000)});
    const response=await app.fetch(`https://scriv.test${path}/commands`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json'},body:payload});
    expect(response.status).toBe(413);expect((await response.json<any>()).error.code).toBe('body_too_large');
    // Oversized-body cancellation must not poison the room or its next request.
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(1);
    expect((await call(`${path}/commands`,owner.token,'POST',command([put(scene('after-rejection'))]))).status).toBe(200);
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(2);
  });
});

describe('authorized project mentions',()=>{
  it('lists only project members with bounded pagination and literal display-name search',async()=>{
    const {owner,path,team}=await setup(true),viewer=await user('Viewer_100%'),member=await user('Member'),outsider=await user('Outsider');
    for(const [person,role] of [[viewer,'viewer'],[member,'member']] as const)await env.DB.prepare('INSERT INTO team_members VALUES(?,?,?,?)').bind(team!,person.uid,role,Date.now()).run();
    const found:any[]=[];let cursor:string|null=null;
    do{const page=await call(`${path}/members?limit=1${cursor?`&after=${cursor}`:''}`,viewer.token);expect(page.status).toBe(200);expect(page.data.members).toHaveLength(1);found.push(...page.data.members);cursor=page.data.nextCursor;}while(cursor);
    expect(found.map(value=>value.id).sort()).toEqual([owner.uid,viewer.uid,member.uid].sort());
    expect(found.every(value=>Object.keys(value).sort().join(',')==='id,name,role')).toBe(true);
    expect((await call(`${path}/members?q=%25`,viewer.token)).data.members).toEqual([{id:viewer.uid,name:'Viewer_100%',role:'viewer'}]);
    expect((await call(`${path}/members`,outsider.token)).status).toBe(404);
    expect((await call(`${path}/members?limit=201`,owner.token)).status).toBe(400);
    await env.DB.prepare('DELETE FROM team_members WHERE team_id=? AND user_id=?').bind(team!,owner.uid).run();
    expect((await call(`${path}/members`,owner.token)).data.members.find((value:any)=>value.id===owner.uid).role).toBe('owner');
    const solo=await setup();expect((await call(`${solo.path}/members`,solo.owner.token)).data.members).toEqual([{id:solo.owner.uid,name:'Writer',role:'owner'}]);
  });
  it('allows a paid viewer to mention members and persists IDs through replay and eviction',async()=>{
    const {owner,path,project,team}=await setup(true),viewer=await user('Viewer');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'viewer',?)").bind(team!,viewer.uid,Date.now()).run();
    const thread=(await call(`${path}/threads`,viewer.token,'POST',{})).data.thread;
    const payload={id:'viewer-mention',body:'Please review.',mentionedUserIds:[viewer.uid,owner.uid]};
    const posted=await call(`${path}/threads/${thread.id}/messages`,viewer.token,'POST',payload);expect(posted.status).toBe(201);expect(posted.data.message.mentionedUserIds).toEqual([owner.uid,viewer.uid].sort());
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token)).data.messages[0]).toEqual(posted.data.message);
    expect((await call(`${path}/events?after=2`,owner.token)).data.events[0].data.message).toEqual(posted.data.message);
    expect((await call(`${path}/threads/${thread.id}/messages`,viewer.token,'POST',{...payload,mentionedUserIds:[owner.uid,viewer.uid]})).data).toEqual(posted.data);
    expect((await call(`${path}/commands`,viewer.token,'POST',command([put(scene('viewer-edit'))]))).status).toBe(403);
  });
  it('rejects invalid recipient lists and nonmembers without advancing the journal',async()=>{
    const {owner,path}=await setup(),outsider=await user('Outsider'),thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread;
    for(const mentionedUserIds of [null,'member',[owner.uid,owner.uid],Array(21).fill(owner.uid),[outsider.uid],['missing-member']]){
      const result=await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:crypto.randomUUID(),body:'Mention.',mentionedUserIds});expect(result.status).toBe(400);expect(result.data.error.code).toBe('invalid_mentions');
    }
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(2);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:'plain',body:'No mentions.'})).data.message.mentionedUserIds).toEqual([]);
  });
  it('recovers accepted sends after recipient removal but rejects new sends and changed recipients',async()=>{
    const {owner,path,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread,payload={id:'mention',body:'Please review.',mentionedUserIds:[member.uid]};
    const accepted=await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload);expect(accepted.status).toBe(201);
    expect((await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'DELETE')).status).toBe(200);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload)).data).toEqual(accepted.data);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{...payload,id:'new-mention'})).data.error.code).toBe('invalid_mentions');
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{...payload,mentionedUserIds:[owner.uid]})).data.error.code).toBe('message_reused');
  });
  it('serializes identical concurrent mentioned sends across membership lookup awaits',async()=>{
    const {owner,path}=await setup(),thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread,payload={id:'same-mention',body:'One message.',mentionedUserIds:[owner.uid]};
    const sends=await Promise.all(Array.from({length:8},()=>call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',payload)));
    expect(sends.filter(value=>value.status===201)).toHaveLength(1);expect(sends.every(value=>value.status===200||value.status===201)).toBe(true);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token)).data.messages).toHaveLength(1);
  });
  it('fences a slow mentioned send when the recipient leaves before its body arrives',async()=>{
    const {owner,path,project,team}=await setup(true),member=await user('Member');await env.DB.prepare("INSERT INTO team_members VALUES(?,?,'member',?)").bind(team!,member.uid,Date.now()).run();
    const thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread,payload={id:'slow-mention',body:'Too late.',mentionedUserIds:[member.uid]};
    const delayed=await slowAuthorizedPost(project,`${path}/threads/${thread.id}/messages`,owner.token,payload);
    await call(`/v1/teams/${team}/members/${member.uid}`,owner.token,'DELETE');expect((await delayed.finish()).data.error.code).toBe('access_changed');
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token)).data.messages).toHaveLength(0);
  });
  it('migrates pre-mention persisted messages without changing their IDs or timestamps',async()=>{
    const {owner,path,project}=await setup(),thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread;
    const stub=env.PROJECTS.get(env.PROJECTS.idFromName(project));
    await runInDurableObject(stub,(_instance,state)=>{
      state.storage.sql.exec('INSERT INTO messages(id,thread_id,user_id,name,body,attachments,at) VALUES(?,?,?,?,?,?,?)','old-message',thread.id,owner.uid,'Writer','Before mentions','[]',123);
      state.storage.sql.exec('ALTER TABLE messages DROP COLUMN mentioned_user_ids');state.storage.sql.exec('DELETE FROM schema_migrations WHERE version=3');
    });
    await evictDurableObject(stub);
    expect((await call(`${path}/threads/${thread.id}/messages`,owner.token)).data.messages[0]).toMatchObject({id:'old-message',body:'Before mentions',at:123,mentionedUserIds:[]});
    expect(await runInDurableObject(stub,(_instance,state)=>state.storage.sql.exec('SELECT version FROM schema_migrations WHERE version=3').toArray())).toHaveLength(1);
  });
});

describe('image-lineage and archived discussion discovery',()=>{
  const revision=(id:string,version:number,previousVersionId?:string)=>({...image(id),data:{...image(id).data,version,...(previousVersionId?{previousVersionId}:{})}});
  it('retains one conversation across regeneration and keeps the originally selected version anchor',async()=>{
    const {owner,path,project}=await setup();
    expect((await call(`${path}/commands`,owner.token,'POST',command([put(revision('image-root',1)),put(revision('image-v2',2,'image-root'))]))).status).toBe(200);
    const started=await call(`${path}/threads`,owner.token,'POST',{itemId:'image-v2'});expect(started.status).toBe(201);expect(started.data.thread).toMatchObject({itemId:'image-root',anchor:{imageVersionId:'image-v2'}});
    await call(`${path}/commands`,owner.token,'POST',command([put(revision('image-v3',3,'image-v2'))]));
    const head=(await call(`${path}/snapshot`,owner.token)).data.headSeq;
    for(const itemId of ['image-root','image-v2','image-v3']){
      expect((await call(`${path}/threads`,owner.token,'POST',{itemId})).data.thread).toEqual(started.data.thread);
      expect((await call(`${path}/threads?itemId=${itemId}`,owner.token)).data.threads).toEqual([started.data.thread]);
    }
    expect((await call(`${path}/snapshot`,owner.token)).data.headSeq).toBe(head);
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)));
    expect((await call(`${path}/threads?itemId=image-v3`,owner.token)).data.threads[0].id).toBe(started.data.thread.id);
  });
  it('preserves legacy version forks and exposes resolved/deleted-item discussions only to readers',async()=>{
    const {owner,path,project}=await setup(),outsider=await user('Outsider');
    await call(`${path}/commands`,owner.token,'POST',command([put(revision('image-root',1)),put(revision('image-v2',2,'image-root')),put(revision('image-v3',3,'image-v2'))]));
    await runInDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(project)),(_instance,state)=>{
      for(const [threadId,itemId,at] of [['legacy-v2','image-v2',100],['legacy-v3','image-v3',200]] as const)state.storage.sql.exec('INSERT INTO threads(id,item_id,anchor,resolved,created_at,updated_at) VALUES(?,?,?,1,?,?)',threadId,itemId,JSON.stringify({imageVersionId:itemId}),at,at);
      state.storage.sql.exec("UPDATE items SET deleted=1 WHERE kind='image'");
    });
    expect((await call(`${path}/threads`,owner.token,'POST',{itemId:'image-v3'})).data.thread.id).toBe('legacy-v2');
    const first=await call(`${path}/threads?scope=all&limit=1`,owner.token);expect(first.data.threads[0].id).toBe('legacy-v2');expect(first.data.hasMore).toBe(true);
    const second=await call(`${path}/threads?scope=all&limit=1&after=${first.data.nextCursor}`,owner.token);expect(second.data.threads[0].id).toBe('legacy-v3');expect(second.data.hasMore).toBe(false);
    expect((await call(`${path}/threads/legacy-v3`,owner.token)).status).toBe(200);expect((await call(`${path}/threads?scope=all`,outsider.token)).status).toBe(404);
    expect((await call(`${path}/threads?scope=all&itemId=image-v3`,owner.token)).status).toBe(400);
    expect((await call(`${path}/threads?scope=all&limit=201`,owner.token)).status).toBe(400);
  });
  it('fails closed for invalid image lineage and rejects unrelated image anchors',async()=>{
    const {owner,path,project}=await setup();await call(`${path}/commands`,owner.token,'POST',command([put(revision('image-root',1)),put(revision('other-image',1))]));
    expect((await call(`${path}/threads`,owner.token,'POST',{itemId:'image-root',anchor:{imageVersionId:'other-image'}})).data.error.code).toBe('invalid_anchor');
    const stub=env.PROJECTS.get(env.PROJECTS.idFromName(project));
    for(const previousVersionId of ['missing-image','image-root']){
      await runInDurableObject(stub,(_instance,state)=>{state.storage.sql.exec("UPDATE items SET data=json_set(data,'$.previousVersionId',?) WHERE id='image-root'",previousVersionId);});
      expect((await call(`${path}/threads`,owner.token,'POST',{itemId:'image-root'})).data.error.code).toBe('invalid_image_lineage');
      expect((await call(`${path}/threads?itemId=image-root`,owner.token)).data.error.code).toBe('invalid_image_lineage');
    }
    expect((await call(`${path}/threads?scope=all`,owner.token)).data.threads).toEqual([]);
  });
});

describe('read-only historical snapshot projection',()=>{
  it('reconstructs import and restore history without modifying current content or discussion',async()=>{
    const owner=await user(),project=(await call('/v1/projects',owner.token,'POST',{title:'History'})).data.project.id,path=`/v1/projects/${project}`;
    const imported=await call(`${path}/import`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:0,items:[scene(),entry()]});expect(imported.data.snapshotRequired).toBe(true);
    const thread=(await call(`${path}/threads`,owner.token,'POST',{})).data.thread;await call(`${path}/threads/${thread.id}/messages`,owner.token,'POST',{id:'history-chat',body:'Discussion is not restored.'});
    const lease=await claim(path,owner.token);await call(`${path}/commands`,owner.token,'POST',command([{op:'delete',id:'entry',expectedVersion:1,lease}],{expectedTimingVersion:1}));
    const restore=await call(`${path}/restore`,owner.token,'POST',{commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,seq:0});expect(restore.status).toBe(200);
    const before=(await call(`${path}/snapshot`,owner.token)).data;
    const importedPreview=(await call(`${path}/snapshot?seq=1`,owner.token)).data;expect(importedPreview.items.map((item:any)=>item.id)).toEqual(['entry','scene']);expect(importedPreview.items.every((item:any)=>item.version===1)).toBe(true);
    expect(importedPreview).toMatchObject({epoch:1,headSeq:1,timingVersion:1,canImport:false,threads:[],leases:[],hasMore:false,historyEvent:{seq:1,actorId:owner.uid,kind:'command'}});
    const restoredPreview=(await call(`${path}/snapshot?seq=${restore.data.seq}&epoch=2`,owner.token)).data;expect(restoredPreview.items).toEqual([]);expect(restoredPreview.deletedItems).toHaveLength(2);expect(restoredPreview.deletedItems.every((item:any)=>Object.keys(item.data).length===0)).toBe(true);
    const empty=(await call(`${path}/snapshot?seq=0`,owner.token)).data;expect(empty).toMatchObject({epoch:1,headSeq:0,timingVersion:0,items:[],deletedItems:[],canImport:false,historyEvent:null});
    expect((await call(`${path}/snapshot`,owner.token)).data).toEqual(before);expect((await call(`${path}/threads/${thread.id}/messages`,owner.token)).data.messages).toHaveLength(1);
  });
  it('paginates an immutable sequence while newer edits arrive',async()=>{
    const {owner,path}=await setup(),first=(await call(`${path}/snapshot?seq=1&limit=1`,owner.token)).data;expect(first.items.map((item:any)=>item.id)).toEqual(['entry']);expect(first.hasMore).toBe(true);
    await call(`${path}/commands`,owner.token,'POST',command([put(scene('new-scene'))]));
    const second=(await call(`${path}/snapshot?seq=1&limit=1&after=${first.nextCursor}`,owner.token)).data;expect(second.items.map((item:any)=>item.id)).toEqual(['scene']);expect(second.hasMore).toBe(false);expect(second.headSeq).toBe(1);
  });
  it('bounds preview payloads independently from the requested item count',async()=>{
    const {owner,path}=await setup();
    for(let offset=0;offset<20;offset+=5){const operations=Array.from({length:5},(_,index)=>{const id=`character-${String(offset+index).padStart(2,'0')}`;return put({id,kind:'character',data:{id,name:id,aliases:[],biography:'a'.repeat(20000),appearance:'b'.repeat(20000),color:'blue'}});});expect((await call(`${path}/commands`,owner.token,'POST',command(operations))).status).toBe(200);}
    const head=(await call(`${path}/snapshot`,owner.token)).data.headSeq,preview=(await call(`${path}/snapshot?seq=${head}&limit=200`,owner.token)).data;
    expect(preview.hasMore).toBe(true);expect(preview.items.length).toBeLessThan(20);expect(preview.items.reduce((bytes:number,item:any)=>bytes+new TextEncoder().encode(JSON.stringify(item)).byteLength,0)).toBeLessThanOrEqual(524288);
  });
  it('rejects unauthorized, invalid or mismatched historical requests',async()=>{
    const {owner,path}=await setup(),outsider=await user('Outsider');
    for(const suffix of ['seq=2','seq=-1','seq=0.5','seq=NaN','seq=1&limit=201'])expect((await call(`${path}/snapshot?${suffix}`,owner.token)).status).toBe(400);
    expect((await call(`${path}/snapshot?seq=1&epoch=2`,owner.token)).data.error.code).toBe('history_epoch_mismatch');
    expect((await call(`${path}/snapshot?seq=0`,outsider.token)).status).toBe(404);
  });
});
