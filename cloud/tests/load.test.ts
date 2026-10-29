import { beforeEach, afterEach, expect, it } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, reset } from 'cloudflare:test';
import { sha256 } from '../src/http';
import type { Env } from '../src/types';
const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[];RUN_LOAD_TEST:boolean};
const app=(exports as any).default;
const sockets:WebSocket[]=[];
beforeEach(async()=>{if(env.RUN_LOAD_TEST)await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
afterEach(async()=>{for(const socket of sockets)socket.close();if(env.RUN_LOAD_TEST)await reset();});
const percentile=(times:number[],p:number)=>times.toSorted((a,b)=>a-b)[Math.min(times.length-1,Math.floor(times.length*p))];
const api=async(path:string,token:string,method='GET',data?:unknown)=>{const response=await app.fetch(`https://scriv.test${path}`,{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:data===undefined?undefined:JSON.stringify(data)});const value=await response.json<any>();expect(response.status,JSON.stringify(value)).toBeLessThan(300);return value;};
it.skipIf(!env.RUN_LOAD_TEST)('supports 500 connected members and 100 independent text writers in one project',async(context)=>{
 const people=await Promise.all(Array.from({length:500},async(_,i)=>{const token=crypto.randomUUID();return{id:`member-${i}`,sessionId:`session-${i}`,token,hash:await sha256(token)};}));
 const now=Date.now(),team='load-team',project='load-project';
 for(let i=0;i<people.length;i+=40){await env.DB.batch(people.slice(i,i+40).flatMap(p=>[
  env.DB.prepare('INSERT INTO users(id,github_id,name,created_at)VALUES(?,?,?,?)').bind(p.id,p.id,p.id,now),
  env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)VALUES(?,?,?,?,?,?)').bind(p.hash,p.sessionId,p.id,'Mac',now,now+86400000)
 ]));}
 await env.DB.prepare("INSERT INTO teams(id,name,owner_id,created_at,subscription_status,paid_until,current_period_end)VALUES(?,?,?,?,'active',?,?)").bind(team,'Load team',people[0]!.id,now,now+86400000,now+86400000).run();
 for(let i=0;i<people.length;i+=80)await env.DB.batch(people.slice(i,i+80).map(p=>env.DB.prepare('INSERT INTO team_members(team_id,user_id,role,joined_at)VALUES(?,?,?,?)').bind(team,p.id,p.id==='member-0'?'owner':'member',now)));
 await api('/v1/projects',people[0]!.token,'POST',{id:project,title:'Load verification',teamId:team});
 const entries=Array.from({length:100},(_,i)=>({id:`line-${i}`,kind:'entry',data:{id:`line-${i}`,sceneId:'scene',order:i,kind:'dialogue',text:'Hello world.',ownedDurationMs:2000,coverageDurationMs:0,color:'blue',words:[{id:`w-${i}-1`,text:'Hello',startMs:0,endMs:1000},{id:`w-${i}-2`,text:'world.',startMs:1000,endMs:2000}]}}));
 await api(`/v1/projects/${project}/import`,people[0]!.token,'POST',{commandId:'import',sessionId:'editor-owner',epoch:1,expectedTimingVersion:0,items:[{id:'scene',kind:'scene',data:{id:'scene',title:'Scene',order:0}},...entries]});
 const connectTimes:number[]=[],writeTimes:number[]=[],deliveryTimes:number[]=[];let delivered=0;const expectedSequence=new Set<number>();
 const batchStarted=performance.now();
 for(let i=0;i<people.length;i+=50){await Promise.all(people.slice(i,i+50).map(async p=>{
  const start=performance.now();const response=await app.fetch(`https://scriv.test/v1/projects/${project}/socket`,{headers:{authorization:`Bearer ${p.token}`,upgrade:'websocket'}});expect(response.status).toBe(101);const socket=response.webSocket!;sockets.push(socket);
  const ready=new Promise<void>(resolve=>socket.addEventListener('message',(event:MessageEvent)=>{const value=JSON.parse(String(event.data));if(value.type==='hello')resolve();const events=value.type==='event'?[value.event]:value.type==='events'?value.events:[];for(const changed of events){delivered++;if(p.id==='member-499'){expectedSequence.add(changed.seq);deliveryTimes.push(performance.now()-(writeStarts.get(changed.commandId)??performance.now()));}}}));
  socket.accept();await ready;connectTimes.push(performance.now()-start);
 }));}
 const writeStarts=new Map<string,number>();
 sockets.forEach((socket,i)=>socket.send(JSON.stringify({type:'presence',itemId:`line-${i%100}`,selection:{start:0,end:1},name:'untrusted name'})));
 const leases=await Promise.all(people.slice(0,100).map((p,i)=>api(`/v1/projects/${project}/leases`,p.token,'POST',{itemId:`line-${i}`,sessionId:`editor-${i}`})));
 await Promise.all(people.slice(0,100).map(async(p,i)=>{
  const item=structuredClone(entries[i]!);item.data.text='Goodbye world.';item.data.words[0]!.text='Goodbye';const commandId=`write-${i}`,start=performance.now();writeStarts.set(commandId,start);
  await api(`/v1/projects/${project}/commands`,p.token,'POST',{commandId,sessionId:`editor-${i}`,epoch:1,expectedTimingVersion:1,label:'Edit independent dialogue',operations:[{op:'put',...item,expectedVersion:1,lease:{token:leases[i].token,fence:leases[i].fence}}]});writeTimes.push(performance.now()-start);
 }));
 const snapshot=await api(`/v1/projects/${project}/snapshot`,people[0]!.token);expect(snapshot.headSeq).toBe(101);expect(snapshot.items.filter((i:any)=>i.kind==='entry'&&i.data.text==='Goodbye world.')).toHaveLength(100);
 // A watermark roundtrip confirms event delivery has drained through the room.
 const received=new Promise<void>(resolve=>sockets[499]!.addEventListener('message',(e:MessageEvent)=>{const value=JSON.parse(String(e.data));if(value.type==='watermark'&&value.headSeq===101)resolve();}));sockets[499]!.send(JSON.stringify({type:'ping',after:0}));await received;
 expect(expectedSequence.size).toBe(100);expect(delivered).toBe(50000);
 const metrics={connections:500,concurrentWriters:100,acceptedWrites:100,deliveredEvents:delivered,connectP95Ms:percentile(connectTimes,.95),writeAckP95Ms:percentile(writeTimes,.95),observerDeliveryP95Ms:percentile(deliveryTimes,.95),totalMs:performance.now()-batchStarted,environment:'local workerd, not a production latency SLA'};
 context.task.name += ' | ' + JSON.stringify(metrics);
 console.warn('SCRIV_LOAD_RESULT',JSON.stringify(metrics));
},120000);
