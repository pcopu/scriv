import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, reset, runInDurableObject } from 'cloudflare:test';
import type { Env } from '../src/types';
import { sha256 } from '../src/http';

const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[]};
const app=(exports as any).default;
const sockets:WebSocket[]=[];
beforeEach(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
afterEach(async()=>{for(const socket of sockets.splice(0))socket.close();await reset();});
async function call(path:string,token:string,payload:unknown){
  const response=await app.fetch(`https://scriv.test${path}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(payload)});
  expect(response.ok).toBe(true);return response.json<any>();
}
async function setup(){
  const token=crypto.randomUUID(),uid=crypto.randomUUID(),sid=crypto.randomUUID(),now=Date.now();
  await env.DB.prepare('INSERT INTO users(id,github_id,name,created_at)VALUES(?,?,?,?)').bind(uid,uid,'Writer',now).run();
  await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)VALUES(?,?,?,?,?,?)').bind(await sha256(token),sid,uid,'Mac',now,now+86400000).run();
  const team=(await call('/v1/teams',token,{name:'Film'})).team.id;
  await env.DB.prepare("UPDATE teams SET subscription_status='active',paid_until=?,current_period_end=? WHERE id=?").bind(now+86400000,now+86400000,team).run();
  const project=(await call('/v1/projects',token,{title:'Film',teamId:team})).project.id as string,path=`/v1/projects/${project}`;
  await call(`${path}/commands`,token,{commandId:crypto.randomUUID(),sessionId:'writer',epoch:1,expectedTimingVersion:0,label:'Scene',operations:[{op:'put',id:'scene',kind:'scene',expectedVersion:0,data:{id:'scene',title:'Scene',order:0}}]});
  return{token,path,stub:env.PROJECTS.get(env.PROJECTS.idFromName(project))};
}
function waitMessage(socket:WebSocket,predicate:(value:any)=>boolean){return new Promise<any>((resolve,reject)=>{const timer=setTimeout(()=>{socket.removeEventListener('message',handler);reject(Error('presence message timeout'));},3000);const handler=(event:MessageEvent)=>{const value=JSON.parse(String(event.data));if(predicate(value)){clearTimeout(timer);socket.removeEventListener('message',handler);resolve(value);}};socket.addEventListener('message',handler);});}
async function connect(path:string,token:string,delta=true){
  const response=await app.fetch(`https://scriv.test${path}/socket`,{headers:{authorization:`Bearer ${token}`,upgrade:'websocket',...(delta?{'X-Scriv-Presence':'delta-v1'}:{})}});
  expect(response.status).toBe(101);const socket=response.webSocket!;sockets.push(socket);
  const hello=waitMessage(socket,v=>v.type==='hello'),presence=waitMessage(socket,v=>v.type==='presence');socket.accept();
  return{socket,hello:await hello,presence:await presence};
}

describe('bounded trailing-latest presence',()=>{
  it('delivers the final UTF-16 selection after a sub-200ms burst without another input',async()=>{
    const {path,token,stub}=await setup(),reader=await connect(path,token),writer=await connect(path,token);
    await runInDurableObject(stub,(instance:any)=>instance.flushPresence());
    const initial=waitMessage(reader.socket,v=>v.type==='presence-delta'&&v.peers.some((p:any)=>p.connectionId===writer.hello.connectionId&&p.selection?.end===2));
    writer.socket.send(JSON.stringify({type:'presence',itemId:'scene',selection:{start:0,end:2}}));await initial;
    const deliveries:any[]=[];reader.socket.addEventListener('message',(e:MessageEvent)=>{const value=JSON.parse(String(e.data));if(value.type==='presence-delta')deliveries.push(value);});
    // Native offsets are UTF-16 code units (e.g. an emoji occupies two); retain
    // exact endpoints, including a final collapsed caret, without re-tokenizing.
    const trailing=waitMessage(reader.socket,v=>v.type==='presence-delta'&&v.peers.some((p:any)=>p.selection?.start===17&&p.selection?.end===17));
    for(let i=3;i<=17;i++)writer.socket.send(JSON.stringify({type:'presence',itemId:'scene',selection:{start:i,end:i}}));
    const update=await trailing;
    expect(update.peers).toHaveLength(1);expect(update.peers[0].connectionId).toBe(writer.hello.connectionId);
    expect(update.removedConnectionIds).toEqual([]);expect(deliveries.length).toBeLessThanOrEqual(2);
  });
  it('keeps a connected idle reader visible independently of its last cursor movement',async()=>{
    const {path,token,stub}=await setup(),reader=await connect(path,token);
    expect(reader.presence.peers.some((p:any)=>p.connectionId===reader.hello.connectionId)).toBe(true);
    const idle=await runInDurableObject(stub,(instance:any,state)=>{
      const socket=state.getWebSockets()[0]!,a=socket.deserializeAttachment();a.lastPresenceAt=Date.now()-60000;a.lastSeenAt=Date.now()-40000;socket.serializeAttachment(a);
      return instance.peers();
    });expect(idle).toHaveLength(0);
    const pong=waitMessage(reader.socket,v=>v.type==='watermark');reader.socket.send('{"type":"ping"}');await pong;
    const peers=await runInDurableObject(stub,(instance:any)=>instance.peers());
    expect(peers).toHaveLength(1);expect(peers[0].connectionId).toBe(reader.hello.connectionId);
    expect(peers[0].at).toBeLessThan(Date.now()-30000);
  });
  it('sends one removal delta on close while preserving the remaining reader',async()=>{
    const {path,token,stub}=await setup(),reader=await connect(path,token),writer=await connect(path,token);
    await runInDurableObject(stub,(instance:any)=>instance.flushPresence());
    const removed=waitMessage(reader.socket,v=>v.type==='presence-delta'&&v.removedConnectionIds.includes(writer.hello.connectionId));writer.socket.close();
    const update=await removed;expect(update.peers).toEqual([]);expect(update.removedConnectionIds).toEqual([writer.hello.connectionId]);
    const peers=await runInDurableObject(stub,(instance:any)=>instance.peers());expect(peers).toHaveLength(1);
  });
  it('batches a large room without resending its unchanged hundred-reader roster',async()=>{
    const {path,token,stub}=await setup(),clients=await Promise.all(Array.from({length:102},()=>connect(path,token)));
    const reader=clients[0]!,writer=clients[101]!;
    await runInDurableObject(stub,(instance:any)=>instance.flushPresence());
    const update=waitMessage(reader.socket,v=>v.type==='presence-delta'&&v.peers.some((p:any)=>p.connectionId===writer.hello.connectionId&&p.selection?.end===9));
    for(let i=0;i<=9;i++)writer.socket.send(JSON.stringify({type:'presence',itemId:'scene',selection:{start:0,end:i}}));
    const result=await update;expect(result.peers).toHaveLength(1);expect(result.removedConnectionIds).toEqual([]);
    expect(await runInDurableObject(stub,(instance:any)=>instance.peers().length)).toBe(102);
  });
  it('retains full snapshots for legacy clients and repairs a lost delta baseline',async()=>{
    const {path,token,stub}=await setup(),legacy=await connect(path,token,false),writer=await connect(path,token);
    await runInDurableObject(stub,(instance:any)=>instance.flushPresence());
    const full=waitMessage(legacy.socket,v=>v.type==='presence'&&v.peers.some((p:any)=>p.selection?.end===7));
    writer.socket.send(JSON.stringify({type:'presence',itemId:'scene',selection:{start:1,end:7}}));expect((await full).peers).toHaveLength(2);
    const repaired=waitMessage(writer.socket,v=>v.type==='presence'&&v.peers.length===2);
    await runInDurableObject(stub,(instance:any)=>{instance.publishedPresence=undefined;instance.flushPresence();});await repaired;
  });
});
