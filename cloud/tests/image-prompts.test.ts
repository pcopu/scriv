import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { env as bindings, exports } from 'cloudflare:workers';
import { applyD1Migrations, evictDurableObject, reset } from 'cloudflare:test';
import type { Env, Item } from '../src/types';
import { sha256 } from '../src/http';
import { validateItem } from '../src/validation';

const env=bindings as unknown as Env&{TEST_MIGRATIONS:any[]},app=(exports as any).default;
type Draft=Pick<Item,'id'|'kind'|'data'>;
beforeEach(async()=>{await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);});
afterEach(async()=>{await reset();});
async function call(path:string,token:string,method='GET',payload?:unknown){
  const response=await app.fetch(`https://scriv.test${path}`,{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:payload===undefined?undefined:JSON.stringify(payload)});
  return{status:response.status,data:await response.json<any>()};
}
async function personalProject(){
  const uid=crypto.randomUUID(),token=crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users(id,github_id,name,created_at)VALUES(?,?,?,?)').bind(uid,uid,'Writer',Date.now()).run();
  await env.DB.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at)VALUES(?,?,?,?,?,?)').bind(await sha256(token),crypto.randomUUID(),uid,'Mac',Date.now(),Date.now()+86400000).run();
  const created=await call('/v1/projects',token,'POST',{title:'Free personal film'});expect(created.status).toBe(201);
  const project=created.data.project.id as string;
  expect(await env.DB.prepare('SELECT team_id FROM projects WHERE id=?').bind(project).first()).toEqual({team_id:null});
  return{token,project,path:`/v1/projects/${project}`};
}
const image=(id='image',extra:Record<string,unknown>={}):Draft=>({id,kind:'image',data:{id,version:1,fileName:`${id}.png`,sha256:'a'.repeat(64),mimeType:'image/png',byteCount:100,characterIds:[],prompt:'Manual framing direction',createdAt:1000,...extra}});
const put=(item:Draft,expectedVersion=0,lease?:any)=>({op:'put',...item,expectedVersion,...(lease?{lease:{token:lease.token,fence:lease.fence}}:{})});
const command=(operations:unknown[])=>({commandId:crypto.randomUUID(),sessionId:'editor',epoch:1,expectedTimingVersion:0,label:'Save authored content',operations});
async function claim(f:Awaited<ReturnType<typeof personalProject>>,itemId:string){const response=await call(`${f.path}/leases`,f.token,'POST',{itemId,sessionId:'editor'});expect(response.status).toBe(200);return response.data;}

describe('free cloud script, timing and captured image prompt persistence',()=>{
  it('retains exact authored content through eviction, command replay and history without hosting image binaries',async()=>{
    const f=await personalProject(),generationPrompt='Generate one image.\n\nScene brief: 🎬 dawn, "Keep still."\n  Preserve this spacing.\n';
    const scene:Draft={id:'scene',kind:'scene',data:{id:'scene',title:'Dawn',order:0}};
    const entry:Draft={id:'entry',kind:'entry',data:{id:'entry',sceneId:'scene',order:0,kind:'dialogue',text:'Keep still.',ownedDurationMs:1800,coverageDurationMs:0,color:'blue',words:[{id:'word-1',text:'Keep',startMs:120,endMs:650,timingSource:'authored'},{id:'word-2',text:'still.',startMs:900,endMs:1700,timingSource:'authored'}]}};
    const asset=image('generated',{generationPrompt}),items=[scene,entry,asset],payload=command(items.map(item=>put(item)));
    const saved=await call(`${f.path}/commands`,f.token,'POST',payload);expect(saved.status).toBe(200);expect(saved.data.timingVersion).toBe(1);
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(f.project)));
    const snapshot=await call(`${f.path}/snapshot`,f.token);expect(snapshot.status).toBe(200);expect(snapshot.data.headSeq).toBe(1);
    for(const item of items)expect(snapshot.data.items.find((value:Item)=>value.id===item.id)).toMatchObject(item);
    expect((await call(`${f.path}/commands`,f.token,'POST',payload)).data).toEqual(saved.data);
    const replay=await call(`${f.path}/events?after=0`,f.token);expect(replay.status).toBe(200);expect(replay.data.events).toHaveLength(1);
    for(const item of items)expect(replay.data.events[0].changes.find((change:any)=>change.id===item.id).after).toMatchObject(item);
    const historical=await call(`${f.path}/snapshot?seq=1`,f.token);expect(historical.status).toBe(200);
    expect(historical.data.items.find((item:Item)=>item.id===asset.id).data).toEqual(asset.data);
    expect((await env.MEDIA.list()).objects).toEqual([]);
    expect((await env.DB.prepare('SELECT * FROM assets').all()).results).toEqual([]);
    const upload=await app.fetch(`https://scriv.test${f.path}/assets/${asset.data.sha256}`,{method:'PUT',headers:{authorization:`Bearer ${f.token}`,'content-type':'image/png'},body:new Uint8Array([137,80,78,71,13,10,26,10])});
    expect(upload.status).toBe(402);expect((await upload.json<any>()).error.code).toBe('team_subscription_required');
    expect((await env.MEDIA.list()).objects).toEqual([]);
    expect((await env.DB.prepare('SELECT * FROM assets').all()).results).toEqual([]);
  });

  it('retains distinct immutable submitted prompts on two image versions while manual directions remain editable',async()=>{
    const f=await personalProject(),first=image('first',{generationPrompt:'Exact first submitted prompt.\nWide view.'}),second=image('second',{version:2,previousVersionId:'first',sha256:'b'.repeat(64),generationPrompt:'Exact second submitted prompt.\nClose view.'});
    expect((await call(`${f.path}/commands`,f.token,'POST',command([put(first),put(second)]))).status).toBe(200);
    for(const asset of [first,second]){
      const lease=await claim(f,asset.id);
      for(const generationPrompt of ['Rewritten captured prompt',null,undefined]){
        const changed={...asset,data:{...asset.data,generationPrompt}};
        const rejected=await call(`${f.path}/commands`,f.token,'POST',command([put(changed,1,lease)]));
        expect(rejected.status).toBe(409);expect(rejected.data.error.code).toBe('immutable_image');
      }
      const edited={...asset,data:{...asset.data,prompt:'New manual direction, not generation history'}};
      expect((await call(`${f.path}/commands`,f.token,'POST',command([put(edited,1,lease)]))).status).toBe(200);
    }
    await evictDurableObject(env.PROJECTS.get(env.PROJECTS.idFromName(f.project)));
    const snapshot=(await call(`${f.path}/snapshot`,f.token)).data;
    for(const asset of [first,second])expect(snapshot.items.find((value:Item)=>value.id===asset.id)).toMatchObject({version:2,data:{...asset.data,prompt:'New manual direction, not generation history'}});
    const historical=(await call(`${f.path}/snapshot?seq=1`,f.token)).data;
    for(const asset of [first,second])expect(historical.items.find((value:Item)=>value.id===asset.id).data).toEqual(asset.data);
    const replay=(await call(`${f.path}/events?after=0`,f.token)).data.events;
    expect(replay).toHaveLength(3);
    for(const event of replay)for(const change of event.changes){const original=[first,second].find(asset=>asset.id===change.id)!;expect(change.after.data.generationPrompt).toBe(original.data.generationPrompt);if(change.before)expect(change.before.data.generationPrompt).toBe(original.data.generationPrompt);}
  });

  it('keeps absent legacy and null imported provenance truthful and refuses later synthetic backfill',async()=>{
    const f=await personalProject(),legacy=image('legacy'),imported=image('imported',{generationPrompt:null});
    expect((await call(`${f.path}/commands`,f.token,'POST',command([put(legacy),put(imported)]))).status).toBe(200);
    for(const asset of [legacy,imported]){
      const lease=await claim(f,asset.id),backfilled={...asset,data:{...asset.data,generationPrompt:'Guessed from current script'}};
      const rejected=await call(`${f.path}/commands`,f.token,'POST',command([put(backfilled,1,lease)]));expect(rejected.status).toBe(409);expect(rejected.data.error.code).toBe('immutable_image');
      const edited={...asset,data:{...asset.data,prompt:'Revised manual direction'}};
      expect((await call(`${f.path}/commands`,f.token,'POST',command([put(edited,1,lease)]))).status).toBe(200);
    }
    const snapshot=(await call(`${f.path}/snapshot`,f.token)).data;
    expect(snapshot.items.find((item:Item)=>item.id==='legacy').data).not.toHaveProperty('generationPrompt');
    expect(snapshot.items.find((item:Item)=>item.id==='imported').data.generationPrompt).toBeNull();
  });

  it('rejects malformed and oversized submitted prompts atomically without persisting private context objects',async()=>{
    const f=await personalProject();
    for(const generationPrompt of [42,true,[],{prompt:'Text',referencePaths:['/private/local-reference.png'],credentials:'never-store'},'x'.repeat(30001),'🎬'.repeat(15000)+'x']){
      const rejected=await call(`${f.path}/commands`,f.token,'POST',command([put(image('invalid',{generationPrompt}))]));
      expect(rejected.status).toBe(400);expect(rejected.data.error.code).toBe('invalid_field');
    }
    const overBudget=await call(`${f.path}/commands`,f.token,'POST',command([put(image('over-budget',{prompt:'x'.repeat(30000),generationPrompt:'界'.repeat(20000)}))]));
    expect(overBudget.status).toBe(413);expect(overBudget.data.error.code).toBe('item_too_large');
    expect((await call(`${f.path}/snapshot`,f.token)).data).toMatchObject({headSeq:0,items:[]});
    expect((await call(`${f.path}/events?after=0`,f.token)).data.events).toEqual([]);
  });

  it('accepts exact scalar UTF-16 boundaries only within the existing total item byte budget',()=>{
    for(const generationPrompt of [undefined,null,'','x'.repeat(30000),'🎬'.repeat(15000)])expect(()=>validateItem(image('boundary',{generationPrompt}))).not.toThrow();
    expect(()=>validateItem(image('two-fields',{prompt:'x'.repeat(30000),generationPrompt:'y'.repeat(30000)}))).not.toThrow();
    expect(()=>validateItem(image('utf16-overflow',{generationPrompt:'🎬'.repeat(15000)+'x'}))).toThrow(expect.objectContaining({status:400,code:'invalid_field'}));
    expect(()=>validateItem(image('byte-overflow',{generationPrompt:'界'.repeat(30000)}))).toThrow(expect.objectContaining({status:413,code:'item_too_large'}));
  });

  it('does not expand generation-job routes to accept prompts, local paths, executable metadata or credentials',async()=>{
    const f=await personalProject(),path=`${f.path}/generation-jobs`,input={id:crypto.randomUUID(),targetItemId:'cue',sourceRevision:0};
    expect((await call(path,f.token,'POST',input)).status).toBe(201);
    const privateFields=['generationPrompt','prompt','referencePaths','referenceSnapshots','outputDirectory','executable','credentials'];
    for(const key of privateFields){
      const privateValue='private-not-shared';
      const created=await call(path,f.token,'POST',{...input,id:crypto.randomUUID(),[key]:privateValue});expect(created.status).toBe(400);expect(created.data.error.code).toBe('invalid_field');
      const claimed=await call(`${path}/${input.id}/claim`,f.token,'POST',{operationId:crypto.randomUUID(),expectedVersion:1,[key]:privateValue});expect(claimed.status).toBe(400);expect(claimed.data.error.code).toBe('invalid_field');
      const updated=await call(`${path}/${input.id}`,f.token,'PATCH',{operationId:crypto.randomUUID(),expectedVersion:1,status:'cancelled',[key]:privateValue});expect(updated.status).toBe(400);expect(updated.data.error.code).toBe('invalid_field');
    }
    const jobs=(await env.DB.prepare('SELECT * FROM generation_jobs').all()).results;expect(jobs).toHaveLength(1);expect(jobs[0]).toMatchObject({status:'queued',version:1});expect(JSON.stringify(jobs)).not.toContain('private-not-shared');
    expect((await env.DB.prepare('SELECT * FROM generation_job_operations').all()).results).toEqual([]);
  });
});
