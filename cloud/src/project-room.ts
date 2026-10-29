import { DurableObject } from 'cloudflare:workers';
import type { Change, Command, Env, Identity, Item, ItemKind, Lease, Operation, ProjectAccess, ProjectEvent } from './types';
import { authenticate, projectAccess } from './access';
import { APIError, assert, body, failure, id, int, json, randomToken, record, sha256, stableJSON, str, uuid } from './http';
import { itemKinds, validateItem } from './validation';

interface ItemRow { id:string;kind:ItemKind;version:number;data:string;deleted:number }
interface LeaseRow { auth_session_id:string;item_id:string;session_id:string;token:string;fence:number;expires_at:number;epoch:number;user_id:string;name:string }
interface EventRow { seq:number;epoch:number;command_id:string;actor_id:string;kind:string;at:number;data:string }
interface Attachment { projectId:string;userId:string;name:string;sessionHash:string;sessionId:string;connectionId:string;expiresAt:number;premiumUntil:number;lastPresenceAt:number;lastMessageAt:number;messageCount:number;presence?:Record<string,unknown> }
interface ThreadRow { id:string;item_id:string|null;anchor:string;resolved:number;created_at:number;updated_at:number }
interface MessageRow { id:string;thread_id:string;user_id:string;name:string;body:string;reply_to_id:string|null;attachments:string;at:number }

const SQL = `
CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY CHECK(id=1),project_id TEXT NOT NULL,epoch INTEGER NOT NULL DEFAULT 1,head_seq INTEGER NOT NULL DEFAULT 0,timing_version INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,kind TEXT NOT NULL,version INTEGER NOT NULL,data TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,scene_id TEXT,ordinal REAL,start_ms INTEGER,end_ms INTEGER,duration_ms INTEGER);
CREATE INDEX IF NOT EXISTS items_scene ON items(scene_id,kind,deleted,ordinal);
CREATE TABLE IF NOT EXISTS leases(item_id TEXT PRIMARY KEY,auth_session_id TEXT NOT NULL,session_id TEXT NOT NULL,token TEXT NOT NULL,fence INTEGER NOT NULL,expires_at INTEGER NOT NULL,epoch INTEGER NOT NULL,user_id TEXT NOT NULL,name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY,epoch INTEGER NOT NULL,command_id TEXT UNIQUE NOT NULL,actor_id TEXT NOT NULL,kind TEXT NOT NULL,at INTEGER NOT NULL,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS changes(seq INTEGER NOT NULL,item_id TEXT NOT NULL,before_json TEXT,after_json TEXT NOT NULL,PRIMARY KEY(seq,item_id));
CREATE INDEX IF NOT EXISTS changes_item ON changes(item_id,seq);
CREATE TABLE IF NOT EXISTS receipts(command_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,request_hash TEXT NOT NULL,result TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY,item_id TEXT,anchor TEXT NOT NULL,resolved INTEGER NOT NULL DEFAULT 0,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS thread_item ON threads(COALESCE(item_id,''));
CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,thread_id TEXT NOT NULL REFERENCES threads(id),user_id TEXT NOT NULL,name TEXT NOT NULL,body TEXT NOT NULL,reply_to_id TEXT,attachments TEXT NOT NULL,at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id,at,id);
CREATE TABLE IF NOT EXISTS signals(id INTEGER PRIMARY KEY AUTOINCREMENT,to_device_id TEXT NOT NULL,from_device_id TEXT NOT NULL,from_user_id TEXT NOT NULL,signal_type TEXT NOT NULL,payload TEXT NOT NULL,at INTEGER NOT NULL,expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS signals_recipient ON signals(to_device_id,id);
INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(1,0);
`;

export class ProjectRoom extends DurableObject<Env> {
  private sql: SqlStorage;
  private lastPresenceBroadcast = 0;
  private pendingEvents: ProjectEvent[] = [];
  private pendingEventBytes = 0;
  private eventFlushScheduled = false;
  constructor(ctx:DurableObjectState,env:Env){super(ctx,env);this.sql=ctx.storage.sql;this.sql.exec(SQL);}
  private rows<T>(query:string,...bindings:(string|number|null)[]):T[]{return this.sql.exec(query,...bindings).toArray() as T[];}
  private one<T>(query:string,...bindings:(string|number|null)[]):T|undefined{return this.rows<T>(query,...bindings)[0];}
  private state(){const value=this.one<{project_id:string;epoch:number;head_seq:number;timing_version:number}>('SELECT * FROM meta WHERE id=1');assert(value,500,'uninitialized','Project state is not initialized.');return value;}
  private item(row:ItemRow):Item{return{id:row.id,kind:row.kind,version:row.version,data:JSON.parse(row.data),deleted:!!row.deleted};}
  private getItem(itemId:string):Item|null {const row=this.one<ItemRow>('SELECT * FROM items WHERE id=?',itemId);return row?this.item(row):null;}
  private allItems(includeDeleted=false):Item[]{return this.rows<ItemRow>(`SELECT * FROM items${includeDeleted?'':' WHERE deleted=0'} ORDER BY kind,id`).map(r=>this.item(r));}
  private lease(row:LeaseRow):Lease{return{itemId:row.item_id,sessionId:row.session_id,token:row.token,fence:row.fence,expiresAt:row.expires_at,epoch:row.epoch,userId:row.user_id,name:row.name};}
  private publicLeases(){return this.rows<LeaseRow>('SELECT * FROM leases WHERE expires_at>?',Date.now()).map(r=>{const {token,...value}=this.lease(r);return value;});}
  private thread(row:ThreadRow){return{id:row.id,itemId:row.item_id,anchor:JSON.parse(row.anchor),resolved:!!row.resolved,createdAt:row.created_at,updatedAt:row.updated_at};}
  private message(row:MessageRow){return{id:row.id,threadId:row.thread_id,userId:row.user_id,name:row.name,body:row.body,replyToId:row.reply_to_id,attachments:JSON.parse(row.attachments),at:row.at};}
  private event(row:EventRow):ProjectEvent {
    const data=JSON.parse(row.data);const skip=data.snapshotRequired===true;
    const changes=skip?[]:this.rows<{item_id:string;before_json:string|null;after_json:string}>('SELECT item_id,before_json,after_json FROM changes WHERE seq=? ORDER BY item_id',row.seq).map(c=>({id:c.item_id,before:c.before_json?JSON.parse(c.before_json):null,after:JSON.parse(c.after_json)}));
    return{seq:row.seq,epoch:row.epoch,commandId:row.command_id,actorId:row.actor_id,kind:row.kind,at:row.at,changes,data};
  }
  private eventPage(after:number,limit=100){const state=this.state();const rows=this.rows<EventRow>('SELECT * FROM events WHERE seq>? ORDER BY seq LIMIT ?',after,limit);return{events:rows.map(r=>this.event(r)),headSeq:state.head_seq,epoch:state.epoch,timingVersion:state.timing_version,hasMore:(rows.at(-1)?.seq??after)<state.head_seq};}
  private broadcast(value:unknown,except?:WebSocket){const text=JSON.stringify(value);for(const socket of this.ctx.getWebSockets()){if(socket===except)continue;const a=socket.deserializeAttachment() as Attachment;if(a.expiresAt<=Date.now()||a.premiumUntil<=Date.now()){try{socket.close(4001,'Access expired');}catch{}continue;}try{socket.send(text);}catch{try{socket.close(1011,'Connection lost');}catch{}}}}
  // Persist commands synchronously, but combine their notifications to avoid one
  // socket send per writer per reader. Reconnect/replay repairs a lost flush.
  private queueEvent(event:ProjectEvent){
    if(!this.ctx.getWebSockets().length)return;
    let notification=event,bytes=new TextEncoder().encode(JSON.stringify(event)).byteLength;
    if(bytes>262144){notification={...event,changes:[],data:{...event.data,snapshotRequired:true}};bytes=new TextEncoder().encode(JSON.stringify(notification)).byteLength;}
    if(this.pendingEvents.length&&(this.pendingEvents.length>=64||this.pendingEventBytes+bytes>262144))this.flushEvents();
    this.pendingEvents.push(notification);this.pendingEventBytes+=bytes;
    if(this.eventFlushScheduled)return;this.eventFlushScheduled=true;
    this.ctx.waitUntil(new Promise<void>(resolve=>setTimeout(resolve,50)).then(()=>{this.eventFlushScheduled=false;this.flushEvents();}));
  }
  private flushEvents(){
    const events=this.pendingEvents.splice(0);this.pendingEventBytes=0;if(!events.length)return;
    const last=events.at(-1)!;this.broadcast({type:'events',events,headSeq:last.seq,epoch:last.epoch,timingVersion:last.data.timingVersion,hasMore:false});
  }
  private send(socket:WebSocket,value:unknown){socket.send(JSON.stringify(value));}
  private putItem(item:Item){const d=item.data;this.sql.exec(`INSERT INTO items(id,kind,version,data,deleted,scene_id,ordinal,start_ms,end_ms,duration_ms) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,version=excluded.version,data=excluded.data,deleted=excluded.deleted,scene_id=excluded.scene_id,ordinal=excluded.ordinal,start_ms=excluded.start_ms,end_ms=excluded.end_ms,duration_ms=excluded.duration_ms`,item.id,item.kind,item.version,JSON.stringify(d),item.deleted?1:0,typeof d.sceneId==='string'?d.sceneId:null,typeof d.order==='number'?d.order:null,typeof d.startMs==='number'?d.startMs:null,typeof d.endMs==='number'?d.endMs:null,typeof d.ownedDurationMs==='number'?d.ownedDurationMs:null);}
  private requireLease(itemId:string,lease:Operation['lease'],sessionId:string,identity:Identity,epoch:number){
    const row=this.one<LeaseRow>('SELECT * FROM leases WHERE item_id=?',itemId);
    assert(row&&lease&&row.token===lease.token&&row.fence===lease.fence&&row.user_id===identity.user.id&&row.auth_session_id===identity.sessionId&&row.session_id===sessionId&&row.epoch===epoch&&row.expires_at>Date.now(),423,'lease_required','Acquire or renew the item edit lease before saving.',{itemId,owner:row&&row.expires_at>Date.now()?{userId:row.user_id,name:row.name,expiresAt:row.expires_at}:null});
  }
  private validateReferences(changes:Change[]){
    const scenes=new Set<string>();
    const reference=(value:unknown,kind:ItemKind,name:string)=>{if(value===undefined||value===null)return;const target=this.getItem(String(value));assert(target&&!target.deleted&&target.kind===kind,400,'invalid_reference',`${name} refers to an unavailable ${kind}.`);};
    for(const change of changes){const item=change.after,d=item.data;
      if(change.before?.data.sceneId)scenes.add(String(change.before.data.sceneId));
      if(d.sceneId)scenes.add(String(d.sceneId));
      if(item.kind==='scene')scenes.add(item.id);
      if(!item.deleted){
        if(item.kind==='entry'){reference(d.sceneId,'scene','sceneId');reference(d.characterId,'character','characterId');}
        if(item.kind==='cue'){reference(d.sceneId,'scene','sceneId');reference(d.imageId,'image','imageId');}
        if(item.kind==='image'){for(const ref of d.characterIds as string[])reference(ref,'character','characterIds');reference(d.previousVersionId,'image','previousVersionId');}
        if(item.kind==='character')reference(d.portraitImageId,'image','portraitImageId');
      } else {
        if(item.kind==='scene')assert(!this.one('SELECT id FROM items WHERE scene_id=? AND deleted=0 LIMIT 1',item.id),409,'item_in_use','Delete the scene contents in the same command before deleting the scene.');
        if(item.kind==='character')assert(!this.one(`SELECT id FROM items WHERE deleted=0 AND ((kind='entry' AND json_extract(data,'$.characterId')=?) OR (kind='image' AND EXISTS(SELECT 1 FROM json_each(items.data,'$.characterIds') WHERE value=?))) LIMIT 1`,item.id,item.id),409,'item_in_use','Remove character links and image tags in the same command before deleting this character.');
        if(item.kind==='image')assert(!this.one(`SELECT id FROM items WHERE deleted=0 AND ((kind='cue' AND json_extract(data,'$.imageId')=?) OR (kind='character' AND json_extract(data,'$.portraitImageId')=?) OR (kind='image' AND json_extract(data,'$.previousVersionId')=?)) LIMIT 1`,item.id,item.id,item.id),409,'item_in_use','This image version is still referenced. Remove its references first.');
      }
    }
    for(const sceneId of scenes){const entries=this.rows<{duration_ms:number}>('SELECT duration_ms FROM items WHERE scene_id=? AND kind=? AND deleted=0',sceneId,'entry');const duration=entries.reduce((sum,e)=>sum+e.duration_ms,0);let end=0;
      assert(duration<=86400000,400,'scene_too_long','A scene cannot exceed 24 hours.');
      for(const cue of this.rows<{start_ms:number;end_ms:number}>('SELECT start_ms,end_ms FROM items WHERE scene_id=? AND kind=? AND deleted=0 ORDER BY start_ms,id',sceneId,'cue')){assert(cue.start_ms>=end&&cue.end_ms<=duration,409,'cue_timing','Image cues must be non-overlapping and remain inside their scene. Resize related cues in the same atomic command.');end=cue.end_ms;}
    }
  }
  private parseCommand(raw:Record<string,unknown>,maxOperations=100):Command {
    const commandId=id(raw.commandId,'commandId'),sessionId=id(raw.sessionId,'sessionId'),epoch=int(raw.epoch,'epoch',1);const label=str(raw.label??'Edit','label',200);
    assert(Array.isArray(raw.operations)&&raw.operations.length>0&&raw.operations.length<=maxOperations,400,'invalid_operations',`A command must contain 1–${maxOperations} item operations.`);
    const seen=new Set<string>();const operations=raw.operations.map((value)=>{const op=record(value,'operation');const itemId=id(op.id);assert(!seen.has(itemId),400,'duplicate_operation','An item can be changed only once in a command.');seen.add(itemId);assert(op.op==='put'||op.op==='delete',400,'invalid_operation','Operation must be put or delete.');
      const expectedVersion=int(op.expectedVersion,'expectedVersion');let data:Record<string,unknown>|undefined,kind:ItemKind|undefined;
      if(op.op==='put'){assert(itemKinds.includes(op.kind as ItemKind),400,'invalid_kind','Unsupported project item kind.');kind=op.kind as ItemKind;data=record(op.data);validateItem({id:itemId,kind,data});}
      let lease:Operation['lease'];if(op.lease){const l=record(op.lease,'lease');lease={token:str(l.token,'lease.token',128),fence:int(l.fence,'lease.fence',1)};}
      return{op:op.op as 'put'|'delete',id:itemId,kind,data,expectedVersion,lease};});
    return{commandId,sessionId,epoch,label,operations,expectedTimingVersion:raw.expectedTimingVersion===undefined?undefined:int(raw.expectedTimingVersion,'expectedTimingVersion')};
  }
  private commit(identity:Identity,command:Command,hash:string,snapshotRequired=false){
    return this.ctx.storage.transactionSync(()=>{
      const previous=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',command.commandId);
      if(previous){assert(previous.user_id===identity.user.id&&previous.request_hash===hash,409,'command_reused','A command ID cannot be reused for a different change.');return{receipt:JSON.parse(previous.result),event:null};}
      const state=this.state();assert(command.epoch===state.epoch,409,'stale_epoch','The project was restored. Refresh it before editing.',{epoch:state.epoch});
      const timingKeys=['sceneId','order','kind','ownedDurationMs','coverageDurationMs','text','words'];
      const touchesTiming=command.operations.some(operation=>{const prior=this.getItem(operation.id),kind=operation.kind??prior?.kind;if(kind!=='entry'&&kind!=='cue')return false;if(!prior||operation.op==='delete')return true;const keys=kind==='entry'?timingKeys:['sceneId','startMs','endMs'];return keys.some(key=>stableJSON(prior.data[key])!==stableJSON(operation.data?.[key]));});
      const changesTimeline=command.operations.some(operation=>{const prior=this.getItem(operation.id),kind=operation.kind??prior?.kind;if(kind!=='entry'&&kind!=='cue')return false;if(!prior||operation.op==='delete')return true;const keys=kind==='entry'?['sceneId','order','kind','ownedDurationMs','coverageDurationMs']:['sceneId','startMs','endMs'];return keys.some(key=>stableJSON(prior.data[key])!==stableJSON(operation.data?.[key]));});
      if(changesTimeline)assert(command.expectedTimingVersion===state.timing_version,409,'timing_conflict','The project timing changed. Refresh and reapply this edit.',{timingVersion:state.timing_version});
      const timingVersion=state.timing_version+(touchesTiming?1:0);
      const changes:Change[]=[];
      for(const operation of command.operations){const existing=this.getItem(operation.id);assert((existing?.version??0)===operation.expectedVersion,409,'version_conflict','This item changed on another device.',{itemId:operation.id,current:existing});if(existing)this.requireLease(operation.id,operation.lease,command.sessionId,identity,state.epoch);
        assert(operation.op!=='delete'||(existing&&!existing.deleted),404,'not_found','The item no longer exists.');assert(!existing||operation.kind===undefined||operation.kind===existing.kind,409,'kind_conflict','An item cannot change kind.');
        const after:Item={id:operation.id,kind:operation.kind??existing!.kind,version:(existing?.version??0)+1,data:operation.data??existing!.data,deleted:operation.op==='delete'};this.putItem(after);changes.push({id:operation.id,before:existing,after});
      }
      this.validateReferences(changes);
      const itemCount=this.one<{n:number}>('SELECT COUNT(*) n FROM items WHERE deleted=0')!.n;assert(itemCount<=50000,413,'project_limit','A project cannot contain more than 50,000 items. Split it into multiple projects.');
      const seq=state.head_seq+1,at=Date.now();const event:ProjectEvent={seq,epoch:state.epoch,commandId:command.commandId,actorId:identity.user.id,kind:'command',at,changes:snapshotRequired?[]:changes,data:{label:command.label,timingVersion,...(snapshotRequired?{snapshotRequired:true}:{})}};
      this.sql.exec('UPDATE meta SET head_seq=?,timing_version=? WHERE id=1',seq,timingVersion);this.sql.exec('INSERT INTO events(seq,epoch,command_id,actor_id,kind,at,data) VALUES(?,?,?,?,?,?,?)',seq,state.epoch,command.commandId,identity.user.id,event.kind,at,JSON.stringify(event.data));
      for(const c of changes)this.sql.exec('INSERT INTO changes(seq,item_id,before_json,after_json) VALUES(?,?,?,?)',seq,c.id,c.before?JSON.stringify(c.before):null,JSON.stringify(c.after));
      const receipt={commandId:command.commandId,seq,epoch:state.epoch,timingVersion,items:snapshotRequired?[]:changes.map(c=>c.after),...(snapshotRequired?{snapshotRequired:true}:{})};
      this.sql.exec('INSERT INTO receipts(command_id,user_id,request_hash,result) VALUES(?,?,?,?)',command.commandId,identity.user.id,hash,JSON.stringify(receipt));
      return{receipt,event};
    });
  }
  private restore(identity:Identity,input:Record<string,unknown>,hash:string){
    const commandId=id(input.commandId,'commandId');id(input.sessionId,'sessionId');const epoch=int(input.epoch,'epoch',1),targetSeq=int(input.seq,'seq');
    return this.ctx.storage.transactionSync(()=>{
      const previous=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',commandId);
      if(previous){assert(previous.user_id===identity.user.id&&previous.request_hash===hash,409,'command_reused','Command ID already used.');return{receipt:JSON.parse(previous.result),event:null};}
      const state=this.state();assert(epoch===state.epoch,409,'stale_epoch','Refresh the project before restoring.');assert(targetSeq<=state.head_seq,400,'invalid_sequence','History sequence is beyond the project head.');
      const historical=this.rows<{after_json:string}>(`SELECT c.after_json FROM changes c JOIN (SELECT item_id,MAX(seq) seq FROM changes WHERE seq<=? GROUP BY item_id) latest ON latest.item_id=c.item_id AND latest.seq=c.seq`,targetSeq).map(r=>JSON.parse(r.after_json) as Item);
      const desired=new Map(historical.filter(i=>!i.deleted).map(i=>[i.id,i]));const current=this.allItems(true);const currentMap=new Map(current.map(i=>[i.id,i]));const seq=state.head_seq+1,newEpoch=state.epoch+1,at=Date.now();
      const changed:Change[]=[];
      for(const item of current){const wanted=desired.get(item.id);if(!wanted&&item.deleted)continue;const after:Item=wanted?{...wanted,version:item.version+1,deleted:false}:{...item,version:item.version+1,deleted:true};if(wanted&&stableJSON(item.data)===stableJSON(wanted.data)&&!item.deleted)continue;this.putItem(after);changed.push({id:item.id,before:item,after});}
      for(const item of desired.values()){if(currentMap.has(item.id))continue;const after={...item,version:1,deleted:false};this.putItem(after);changed.push({id:item.id,before:null,after});}
      const data={label:`Restore history ${targetSeq}`,restoreSeq:targetSeq,snapshotRequired:true,timingVersion:state.timing_version+1};
      this.sql.exec('UPDATE meta SET head_seq=?,epoch=?,timing_version=timing_version+1 WHERE id=1',seq,newEpoch);this.sql.exec('UPDATE leases SET expires_at=0,token=?',randomToken());
      this.sql.exec('INSERT INTO events(seq,epoch,command_id,actor_id,kind,at,data) VALUES(?,?,?,?,?,?,?)',seq,newEpoch,commandId,identity.user.id,'restore',at,JSON.stringify(data));
      for(const c of changed)this.sql.exec('INSERT INTO changes(seq,item_id,before_json,after_json) VALUES(?,?,?,?)',seq,c.id,c.before?JSON.stringify(c.before):null,JSON.stringify(c.after));
      const receipt={commandId,seq,epoch:newEpoch,timingVersion:state.timing_version+1,items:[],snapshotRequired:true};this.sql.exec('INSERT INTO receipts(command_id,user_id,request_hash,result) VALUES(?,?,?,?)',commandId,identity.user.id,hash,JSON.stringify(receipt));
      const event:ProjectEvent={seq,epoch:newEpoch,commandId,actorId:identity.user.id,kind:'restore',at,changes:[],data};return{receipt,event};
    });
  }
  async fetch(request:Request):Promise<Response>{
    try{
      const url=new URL(request.url);const match=/^\/v1\/projects\/([^/]+)\/(.*)$/.exec(url.pathname);assert(match,404,'not_found','Project route not found.');
      const projectId=id(match[1]),route=match[2]!,identity=await authenticate(request,this.env),access=await projectAccess(this.env,projectId,identity.user.id);
      this.sql.exec('INSERT OR IGNORE INTO meta(id,project_id) VALUES(1,?)',projectId);assert(this.state().project_id===projectId,409,'project_identity','Incorrect project room.');
      if(route==='socket'&&request.method==='GET')return this.upgradeSocket(request,identity,access);
      if(route==='snapshot'&&request.method==='GET'){const state=this.state();return json({projectId,epoch:state.epoch,headSeq:state.head_seq,timingVersion:state.timing_version,items:this.allItems(),threads:this.rows<ThreadRow>('SELECT * FROM threads ORDER BY updated_at DESC').map(t=>this.thread(t)),leases:this.publicLeases()});}
      if((route==='events'||route==='history')&&request.method==='GET'){const after=int(Number(url.searchParams.get('after')??0),'after'),limit=int(Number(url.searchParams.get('limit')??100),'limit',1,200);return json(this.eventPage(after,limit));}
      if(route==='import'&&request.method==='POST'){
        const raw=await body(request,16*1024*1024);assert(Array.isArray(raw.items)&&raw.items.length>0,400,'invalid_import','Import must contain project items.');
        const command=this.parseCommand({...raw,label:raw.label??'Import project',operations:raw.items.map(value=>{const item=record(value,'item');return{op:'put',id:item.id,kind:item.kind,data:item.data,expectedVersion:0};})},10000);
        const hash=await sha256(stableJSON(raw));const cached=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',command.commandId);
        if(cached){assert(cached.user_id===identity.user.id&&cached.request_hash===hash,409,'command_reused','Command ID already used.');return json(JSON.parse(cached.result));}
        assert(access.canWrite,403,'read_only','You cannot import into this project.');assert(this.state().head_seq===0,409,'project_not_empty','Atomic import is only available for a new empty project.');
        const {receipt,event}=this.commit(identity,command,hash,true);if(event)this.queueEvent(event);return json(receipt);
      }
      if(route==='commands'&&request.method==='POST'){
        const raw=await body(request);const command=this.parseCommand(raw),hash=await sha256(stableJSON(raw));
        const cached=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',command.commandId);
        if(cached){assert(cached.user_id===identity.user.id&&cached.request_hash===hash,409,'command_reused','Command ID already used.');return json(JSON.parse(cached.result));}
        assert(access.canWrite,403,'read_only','You can read this project but cannot edit it.');
        const {receipt,event}=this.commit(identity,command,hash);if(event)this.queueEvent(event);return json(receipt);
      }
      if(route==='restore'&&request.method==='POST'){assert(access.canManage&&access.canWrite,403,'not_allowed','Only an owner or administrator can restore history.');const raw=await body(request,8192);const {receipt,event}=this.restore(identity,raw,await sha256(stableJSON(raw)));if(event){this.queueEvent(event);this.broadcast({type:'leases',leases:[]});}return json(receipt);}
      if(route==='leases')return await this.handleLeases(request,identity,access);
      if(route==='threads'||route.startsWith('threads/'))return await this.handleDiscussion(request,route,identity,access);
      if(route==='signals')return await this.handleSignals(request,identity,access);
      throw new APIError(404,'not_found','Project route not found.');
    }catch(error){return failure(error);}
  }
  private async handleLeases(request:Request,identity:Identity,access:ProjectAccess):Promise<Response>{
    if(request.method==='GET')return json({leases:this.publicLeases(),epoch:this.state().epoch});
    assert(access.canWrite,403,'read_only','You cannot edit this project.');const raw=await body(request,4096);const itemId=id(raw.itemId,'itemId'),sessionId=id(raw.sessionId,'sessionId');const item=this.getItem(itemId);assert(item,404,'not_found','Item not found.');
    const result=this.ctx.storage.transactionSync(()=>{const state=this.state(),now=Date.now();const current=this.one<LeaseRow>('SELECT * FROM leases WHERE item_id=?',itemId);
      if(request.method==='POST'){
        if(current&&current.expires_at>now&&current.epoch===state.epoch){assert(current.user_id===identity.user.id&&current.auth_session_id===identity.sessionId&&current.session_id===sessionId,423,'item_locked',`${current.name} is editing this item.`,{itemId,userId:current.user_id,name:current.name,expiresAt:current.expires_at});return this.lease(current);}
        const next:Lease={itemId,sessionId,token:randomToken(),fence:(current?.fence??0)+1,expiresAt:now+30000,epoch:state.epoch,userId:identity.user.id,name:identity.user.name};
        this.sql.exec(`INSERT INTO leases(item_id,auth_session_id,session_id,token,fence,expires_at,epoch,user_id,name) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET auth_session_id=excluded.auth_session_id,session_id=excluded.session_id,token=excluded.token,fence=excluded.fence,expires_at=excluded.expires_at,epoch=excluded.epoch,user_id=excluded.user_id,name=excluded.name`,itemId,identity.sessionId,sessionId,next.token,next.fence,next.expiresAt,next.epoch,next.userId,next.name);return next;
      }
      const epoch=int(raw.epoch,'epoch',1);this.requireLease(itemId,{token:str(raw.token,'token',128),fence:int(raw.fence,'fence',1)},sessionId,identity,epoch);assert(epoch===state.epoch,409,'stale_epoch','Project has been restored.');
      if(request.method==='PUT'){this.sql.exec('UPDATE leases SET expires_at=? WHERE item_id=?',now+30000,itemId);return this.lease({...current!,expires_at:now+30000});}
      if(request.method==='DELETE'){this.sql.exec('UPDATE leases SET expires_at=0 WHERE item_id=?',itemId);return{ok:true};}
      throw new APIError(405,'method_not_allowed','Unsupported lease operation.');
    });this.broadcast({type:'leases',leases:this.publicLeases()});return json(result);
  }
  private async handleDiscussion(request:Request,route:string,identity:Identity,access:ProjectAccess):Promise<Response>{
    const url=new URL(request.url);const match=/^threads(?:\/([^/]+)(?:\/(messages))?)?$/.exec(route);assert(match,404,'not_found','Discussion route not found.');
    const threadId=match[1]?id(match[1]):null;
    if(!threadId){
      if(request.method==='GET'){const itemId=url.searchParams.get('itemId');const rows=itemId?this.rows<ThreadRow>('SELECT * FROM threads WHERE item_id=?',id(itemId)):this.rows<ThreadRow>('SELECT * FROM threads WHERE item_id IS NULL');return json({threads:rows.map(t=>this.thread(t))});}
      assert(request.method==='POST',405,'method_not_allowed','Unsupported discussion operation.');assert(access.canWrite||access.premium,403,'read_only','Discussion is read-only for this inactive team.');const input=await body(request,8192);const itemId=input.itemId?id(input.itemId):null;if(itemId)assert(this.getItem(itemId),404,'not_found','Annotated item not found.');const anchor=input.anchor?record(input.anchor,'anchor'):{};
      const existing=itemId?this.one<ThreadRow>('SELECT * FROM threads WHERE item_id=?',itemId):this.one<ThreadRow>('SELECT * FROM threads WHERE item_id IS NULL');if(existing)return json({thread:this.thread(existing)});
      const now=Date.now(),newId=uuid();this.sql.exec('INSERT INTO threads(id,item_id,anchor,created_at,updated_at) VALUES(?,?,?,?,?)',newId,itemId,JSON.stringify(anchor),now,now);const thread=this.thread(this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',newId)!);this.broadcast({type:'thread',thread});return json({thread},201);
    }
    const existing=this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',threadId);assert(existing,404,'not_found','Discussion not found.');
    if(match[2]==='messages'){
      if(request.method==='GET'){const after=int(Number(url.searchParams.get('after')??0),'after'),afterId=url.searchParams.get('afterId')??'';if(afterId)id(afterId,'afterId');const rows=this.rows<MessageRow>('SELECT * FROM messages WHERE thread_id=? AND (at>? OR (at=? AND id>?)) ORDER BY at,id LIMIT 500',threadId,after,after,afterId);const last=rows.at(-1);return json({messages:rows.map(m=>this.message(m)),hasMore:rows.length===500,nextCursor:last?{at:last.at,id:last.id}:null});}
      assert(request.method==='POST',405,'method_not_allowed','Unsupported discussion operation.');assert(access.canWrite||access.premium,403,'read_only','Discussion is read-only for this inactive team.');
      const raw=await body(request,32768);const messageId=id(raw.id,'message.id'),text=str(raw.body,'message.body',8000).trim();assert(text,400,'empty_message','Enter a message.');const reply=raw.replyToId?id(raw.replyToId,'replyToId'):null;const attachments=raw.attachments??[];
      assert(Array.isArray(attachments)&&attachments.length<=20,400,'invalid_attachments','Messages accept up to 20 attachments.');
      for(const value of attachments){const attachment=record(value,'attachment');const target=this.getItem(id(attachment.itemId,'attachment.itemId'));assert(target,404,'not_found','Attachment item not found.');if(attachment.imageVersionId){const version=this.getItem(id(attachment.imageVersionId,'imageVersionId'));assert(version?.kind==='image',404,'not_found','Image version not found.');}}
      if(reply)assert(this.one('SELECT id FROM messages WHERE id=? AND thread_id=?',reply,threadId),400,'invalid_reply','Reply target must be in this thread.');
      const cached=this.one<MessageRow>('SELECT * FROM messages WHERE id=?',messageId);if(cached){assert(cached.user_id===identity.user.id&&cached.thread_id===threadId&&cached.body===text&&cached.reply_to_id===reply&&stableJSON(JSON.parse(cached.attachments))===stableJSON(attachments),409,'message_reused','Message ID already used.');return json({message:this.message(cached)});}
      const at=Date.now();this.ctx.storage.transactionSync(()=>{this.sql.exec('INSERT INTO messages(id,thread_id,user_id,name,body,reply_to_id,attachments,at) VALUES(?,?,?,?,?,?,?,?)',messageId,threadId,identity.user.id,identity.user.name,text,reply,JSON.stringify(attachments),at);this.sql.exec('UPDATE threads SET updated_at=? WHERE id=?',at,threadId);});
      const message=this.message(this.one<MessageRow>('SELECT * FROM messages WHERE id=?',messageId)!);this.broadcast({type:'message',message});return json({message},201);
    }
    if(request.method==='PATCH'){assert(access.canWrite||access.premium,403,'read_only','Discussion is read-only.');const raw=await body(request,4096);assert(typeof raw.resolved==='boolean',400,'invalid_field','resolved must be a boolean.');this.sql.exec('UPDATE threads SET resolved=?,updated_at=? WHERE id=?',raw.resolved?1:0,Date.now(),threadId);const thread=this.thread(this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',threadId)!);this.broadcast({type:'thread',thread});return json({thread});}
    if(request.method==='GET')return json({thread:this.thread(existing)});throw new APIError(405,'method_not_allowed','Unsupported discussion operation.');
  }
  private async handleSignals(request:Request,identity:Identity,access:ProjectAccess):Promise<Response>{
    if(request.method==='GET'){const url=new URL(request.url);const recipient=url.searchParams.get('deviceId')??identity.sessionId;assert(recipient===identity.sessionId,403,'not_allowed','A device can read only its own signaling inbox.');const after=int(Number(url.searchParams.get('after')??0),'after');const rows=this.rows<{id:number;from_device_id:string;from_user_id:string;signal_type:string;payload:string;at:number}>('SELECT * FROM signals WHERE to_device_id=? AND id>? AND expires_at>? ORDER BY id LIMIT 100',recipient,after,Date.now());return json({deviceId:identity.sessionId,signals:rows.map(s=>({id:s.id,fromDeviceId:s.from_device_id,fromUserId:s.from_user_id,type:s.signal_type,payload:JSON.parse(s.payload),at:s.at}))});}
    assert(request.method==='POST',405,'method_not_allowed','Unsupported signaling operation.');const raw=await body(request,65536);await this.routeSignal(raw,identity,access);return json({ok:true});
  }
  private async routeSignal(raw:Record<string,unknown>,identity:Identity,access:ProjectAccess){
    const recipient=id(raw.toDeviceId,'toDeviceId');const type=String(raw.signalType??raw.type);assert(['offer','answer','ice','asset-request','asset-available'].includes(type),400,'invalid_signal','Unsupported peer signal.');
    const target=await this.env.DB.prepare('SELECT user_id FROM sessions WHERE id=? AND revoked_at IS NULL AND expires_at>?').bind(recipient,Date.now()).first<{user_id:string}>();assert(target,404,'peer_unavailable','Peer device is unavailable.');
    const other=await projectAccess(this.env,access.project.id,target.user_id);assert(identity.user.id===target.user_id||access.premium&&other.premium,402,'team_subscription_required','Multiplayer peer exchange requires an active Team subscription.');
    const payload=record(raw.payload,'payload'),encoded=JSON.stringify(payload);assert(encoded.length<=50000,413,'signal_too_large','Peer signals cannot contain image bytes.');const now=Date.now();
    this.sql.exec('DELETE FROM signals WHERE expires_at<?',now);this.sql.exec('INSERT INTO signals(to_device_id,from_device_id,from_user_id,signal_type,payload,at,expires_at) VALUES(?,?,?,?,?,?,?)',recipient,identity.sessionId,identity.user.id,type,encoded,now,now+120000);
    for(const socket of this.ctx.getWebSockets()){const attachment=socket.deserializeAttachment() as Attachment;if(attachment.sessionId===recipient)this.send(socket,{type:'signal',fromDeviceId:identity.sessionId,fromUserId:identity.user.id,signalType:type,payload});}
  }
  private upgradeSocket(request:Request,identity:Identity,access:ProjectAccess):Response {
    assert(request.headers.get('upgrade')?.toLowerCase()==='websocket',426,'websocket_required','Upgrade to WebSocket to join the live project.');assert(access.premium,402,'team_subscription_required','Live multiplayer requires a Team subscription.');
    assert(this.ctx.getWebSockets().length<1000,503,'room_full','This project currently has too many live connections. Retry shortly.');
    const pair=new WebSocketPair();const client=pair[0],server=pair[1];const connectionId=uuid();
    this.ctx.acceptWebSocket(server);server.serializeAttachment({projectId:access.project.id,userId:identity.user.id,name:identity.user.name,sessionHash:identity.tokenHash,sessionId:identity.sessionId,connectionId,expiresAt:identity.expiresAt,premiumUntil:access.team?.paid_until??0,lastPresenceAt:0,lastMessageAt:Date.now(),messageCount:0} satisfies Attachment);
    const state=this.state();this.send(server,{type:'hello',projectId:access.project.id,epoch:state.epoch,headSeq:state.head_seq,timingVersion:state.timing_version,connectionId,deviceId:identity.sessionId});this.send(server,{type:'leases',leases:this.publicLeases()});this.send(server,{type:'presence',peers:this.peers()});
    return new Response(null,{status:101,webSocket:client});
  }
  private peers(){const now=Date.now();return this.ctx.getWebSockets().map(socket=>socket.deserializeAttachment() as Attachment).filter(a=>a.presence&&now-a.lastPresenceAt<30000&&a.expiresAt>now).map(a=>({connectionId:a.connectionId,deviceId:a.sessionId,userId:a.userId,name:a.name,...a.presence,at:a.lastPresenceAt}));}
  private async socketIdentity(socket:WebSocket):Promise<{identity:Identity;access:ProjectAccess;attachment:Attachment}>{
    const a=socket.deserializeAttachment() as Attachment;
    const session=await this.env.DB.prepare('SELECT s.id,s.user_id,s.expires_at,u.name,u.email,u.avatar_url FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?').bind(a.sessionHash,Date.now()).first<{id:string;user_id:string;expires_at:number;name:string;email:string|null;avatar_url:string|null}>();
    assert(session,401,'session_expired','Session expired.');const identity:Identity={user:{id:session.user_id,name:session.name,email:session.email,avatarUrl:session.avatar_url},sessionId:session.id,tokenHash:a.sessionHash,expiresAt:session.expires_at};const access=await projectAccess(this.env,a.projectId,session.user_id);assert(access.premium,402,'team_subscription_required','Team subscription is inactive.');return{identity,access,attachment:a};
  }
  async webSocketMessage(socket:WebSocket,message:string|ArrayBuffer){
    try{
      assert(typeof message==='string'&&message.length<=65536,413,'message_too_large','Live messages must be JSON up to 64 KiB.');const raw=record(JSON.parse(message));const {identity,access,attachment:a}=await this.socketIdentity(socket);
      const now=Date.now();if(now-a.lastMessageAt>1000){a.lastMessageAt=now;a.messageCount=0;}a.messageCount++;assert(a.messageCount<=30,429,'rate_limited','Live messages are arriving too quickly.');socket.serializeAttachment(a);
      if(raw.type==='resume'){this.flushEvents();this.send(socket,{type:'events',...this.eventPage(int(raw.after??0,'after'),100)});return;}
      if(raw.type==='ping'){this.flushEvents();const state=this.state();this.send(socket,{type:'watermark',headSeq:state.head_seq,epoch:state.epoch,timingVersion:state.timing_version});this.send(socket,{type:'presence',peers:this.peers()});return;}
      if(raw.type==='presence'){
        if(now-a.lastPresenceAt<200)return;const presence:Record<string,unknown>={};if(raw.itemId!==undefined&&raw.itemId!==null){presence.itemId=id(raw.itemId,'itemId');assert(this.getItem(presence.itemId as string),404,'not_found','Presence item not found.');}
        if(raw.selection){const selection=record(raw.selection,'selection');presence.selection={start:int(selection.start,'selection.start',0,50000),end:int(selection.end,'selection.end',0,50000)};}
        if(raw.cursor){const cursor=record(raw.cursor,'cursor');assert(typeof cursor.x==='number'&&Number.isFinite(cursor.x)&&typeof cursor.y==='number'&&Number.isFinite(cursor.y),400,'invalid_cursor','Cursor coordinates must be finite.');presence.cursor={x:cursor.x,y:cursor.y};}
        a.presence=presence;a.lastPresenceAt=now;socket.serializeAttachment(a);const presenceInterval=this.ctx.getWebSockets().length>100?1000:200;if(now-this.lastPresenceBroadcast>=presenceInterval){this.lastPresenceBroadcast=now;this.broadcast({type:'presence',peers:this.peers()});}return;
      }
      if(raw.type==='signal'){await this.routeSignal(raw,identity,access);return;}
      throw new APIError(400,'unknown_message','Unsupported live message. Use HTTP commands for durable edits.');
    }catch(error){const code=error instanceof APIError?error.code:'invalid_message';try{this.send(socket,{type:'error',error:{code,message:error instanceof APIError?error.message:'Invalid live message.'}});if(error instanceof APIError&&[401,402,403,404].includes(error.status))socket.close(4001,'Access changed');}catch{}}
  }
  async refreshAccess(userId?:string,sessionId?:string):Promise<void> {
    for(const socket of this.ctx.getWebSockets()){
      const a=socket.deserializeAttachment() as Attachment;if(userId&&a.userId!==userId)continue;if(sessionId&&a.sessionId!==sessionId)continue;
      try{const {access,identity}=await this.socketIdentity(socket);a.expiresAt=identity.expiresAt;a.premiumUntil=access.team?.paid_until??0;socket.serializeAttachment(a);}
      catch{try{socket.close(4001,'Access changed');}catch{}}
    }
  }
  async webSocketClose(socket:WebSocket,code:number,reason:string,wasClean:boolean){try{socket.close(code,reason);}catch{}this.broadcast({type:'presence',peers:this.peers()});}
  async webSocketError(socket:WebSocket){try{socket.close(1011,'Connection error');}catch{}this.broadcast({type:'presence',peers:this.peers()});}
}
