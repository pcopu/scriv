import { DurableObject } from 'cloudflare:workers';
import type { Change, Command, Env, Identity, Item, ItemKind, Lease, Operation, ProjectAccess, ProjectEvent } from './types';
import { authenticate, projectAccess } from './access';
import { APIError, assert, body, failure, id, int, json, randomToken, record, sha256, stableJSON, str, uuid } from './http';
import { itemKinds, validateItem } from './validation';
import { batchLimits, batchManifest, type BatchManifest } from './atomic-batch';

interface ItemRow { id:string;kind:ItemKind;version:number;data:string;deleted:number }
interface LeaseRow { auth_session_id:string;item_id:string;session_id:string;token:string;fence:number;expires_at:number;epoch:number;user_id:string;name:string }
interface EventRow { seq:number;epoch:number;command_id:string;actor_id:string;kind:string;at:number;data:string }
interface Attachment { projectId:string;userId:string;name:string;sessionHash:string;sessionId:string;connectionId:string;expiresAt:number;premiumUntil:number;lastPresenceAt:number;lastSeenAt?:number;lastMessageAt:number;messageCount:number;presence?:Record<string,unknown>;presenceProtocol?:'delta-v1' }
interface BatchRow { command_id:string;user_id:string;auth_session_id:string;request_hash:string;manifest:string;reserved_bytes:number;expires_at:number }
interface ThreadRow { id:string;item_id:string|null;anchor:string;resolved:number;created_at:number;updated_at:number }
interface MessageRow { id:string;thread_id:string;user_id:string;name:string;body:string;reply_to_id:string|null;attachments:string;mentioned_user_ids:string;at:number }

const SQL = `
CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY CHECK(id=1),project_id TEXT NOT NULL,epoch INTEGER NOT NULL DEFAULT 1,head_seq INTEGER NOT NULL DEFAULT 0,timing_version INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,kind TEXT NOT NULL,version INTEGER NOT NULL,data TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,scene_id TEXT,ordinal REAL,start_ms INTEGER,end_ms INTEGER,duration_ms INTEGER);
CREATE INDEX IF NOT EXISTS items_scene ON items(scene_id,kind,deleted,ordinal);
CREATE INDEX IF NOT EXISTS items_image_previous ON items(json_extract(data,'$.previousVersionId')) WHERE kind='image';
CREATE TABLE IF NOT EXISTS word_owners(word_id TEXT NOT NULL,item_id TEXT NOT NULL,PRIMARY KEY(word_id,item_id));
CREATE INDEX IF NOT EXISTS word_owners_item ON word_owners(item_id);
CREATE TABLE IF NOT EXISTS leases(item_id TEXT PRIMARY KEY,auth_session_id TEXT NOT NULL,session_id TEXT NOT NULL,token TEXT NOT NULL,fence INTEGER NOT NULL,expires_at INTEGER NOT NULL,epoch INTEGER NOT NULL,user_id TEXT NOT NULL,name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY,epoch INTEGER NOT NULL,command_id TEXT UNIQUE NOT NULL,actor_id TEXT NOT NULL,kind TEXT NOT NULL,at INTEGER NOT NULL,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS changes(seq INTEGER NOT NULL,item_id TEXT NOT NULL,before_json TEXT,after_json TEXT NOT NULL,PRIMARY KEY(seq,item_id));
CREATE INDEX IF NOT EXISTS changes_item ON changes(item_id,seq);
CREATE TABLE IF NOT EXISTS receipts(command_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,request_hash TEXT NOT NULL,result TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS command_batches(command_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,auth_session_id TEXT NOT NULL,request_hash TEXT NOT NULL,manifest TEXT NOT NULL,reserved_bytes INTEGER NOT NULL,expires_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS command_batch_parts(command_id TEXT NOT NULL,part_index INTEGER NOT NULL,content TEXT NOT NULL,PRIMARY KEY(command_id,part_index));
CREATE INDEX IF NOT EXISTS command_batches_expiry ON command_batches(expires_at);
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
  private presenceFlushScheduled = false;
  private lastPresenceSweep = 0;
  // A fresh/hibernated instance publishes a snapshot before deltas. Presence is
  // ephemeral; losing this baseline must not leave phantom peers on clients.
  private publishedPresence: Map<string,string> | undefined;
  private pendingEvents: ProjectEvent[] = [];
  private pendingEventBytes = 0;
  private eventFlushScheduled = false;
  private accessGeneration = 0;
  private requireCurrentAccess(generation:number){assert(generation===this.accessGeneration,409,'access_changed','Project access changed while this request was in flight. Refresh and retry.');}
  constructor(ctx:DurableObjectState,env:Env){
    super(ctx,env);this.sql=ctx.storage.sql;this.sql.exec(SQL);
    // Forward-only migration: old rooms keep all content/history. The index also
    // preserves pre-existing duplicate word owners so a later edit cannot hide one.
    if(!this.one('SELECT version FROM schema_migrations WHERE version=2'))this.ctx.storage.transactionSync(()=>{
      this.sql.exec(`INSERT OR IGNORE INTO word_owners(word_id,item_id) SELECT json_extract(word.value,'$.id'),items.id FROM items,json_each(items.data,'$.words') word WHERE items.kind='entry' AND items.deleted=0`);
      this.sql.exec('INSERT INTO schema_migrations(version,applied_at) VALUES(2,?)',Date.now());
    });
    if(!this.one('SELECT version FROM schema_migrations WHERE version=3'))this.ctx.storage.transactionSync(()=>{
      this.sql.exec("ALTER TABLE messages ADD COLUMN mentioned_user_ids TEXT NOT NULL DEFAULT '[]'");
      this.sql.exec('INSERT INTO schema_migrations(version,applied_at) VALUES(3,?)',Date.now());
    });
  }
  private rows<T>(query:string,...bindings:(string|number|null)[]):T[]{return this.sql.exec(query,...bindings).toArray() as T[];}
  private one<T>(query:string,...bindings:(string|number|null)[]):T|undefined{return this.rows<T>(query,...bindings)[0];}
  private state(){const value=this.one<{project_id:string;epoch:number;head_seq:number;timing_version:number}>('SELECT * FROM meta WHERE id=1');assert(value,500,'uninitialized','Project state is not initialized.');return value;}
  private item(row:ItemRow):Item{return{id:row.id,kind:row.kind,version:row.version,data:JSON.parse(row.data),deleted:!!row.deleted};}
  private getItem(itemId:string):Item|null {const row=this.one<ItemRow>('SELECT * FROM items WHERE id=?',itemId);return row?this.item(row):null;}
  private allItems(includeDeleted=false):Item[]{return this.rows<ItemRow>(`SELECT * FROM items${includeDeleted?'':' WHERE deleted=0'} ORDER BY kind,id`).map(r=>this.item(r));}
  private lease(row:LeaseRow):Lease{return{itemId:row.item_id,sessionId:row.session_id,token:row.token,fence:row.fence,expiresAt:row.expires_at,epoch:row.epoch,userId:row.user_id,name:row.name};}
  private publicLeases(){return this.rows<LeaseRow>('SELECT * FROM leases WHERE expires_at>?',Date.now()).map(r=>{const {token,...value}=this.lease(r);return value;});}
  private thread(row:ThreadRow){return{id:row.id,itemId:row.item_id,anchor:JSON.parse(row.anchor),resolved:!!row.resolved,createdAt:row.created_at,updatedAt:row.updated_at};}
  private imageRoot(itemId:string):string{
    const visited=new Set<string>();let current=this.getItem(itemId);
    while(true){
      assert(current?.kind==='image',409,'invalid_image_lineage','This image history has a missing or invalid predecessor.');
      assert(!visited.has(current.id)&&visited.size<1000,409,'invalid_image_lineage','This image history contains a cycle or exceeds the supported lineage depth.');
      visited.add(current.id);
      const previous=current.data.previousVersionId;
      if(previous===undefined||previous===null)return current.id;
      const parent=this.getItem(id(previous,'previousVersionId'));
      assert(parent?.kind==='image'&&Number(parent.data.version)<Number(current.data.version),409,'invalid_image_lineage','This image history has a missing or invalid predecessor.');
      current=parent;
    }
  }
  private canonicalThread(itemId:string|null):ThreadRow|undefined{
    if(itemId===null)return this.one<ThreadRow>('SELECT * FROM threads WHERE item_id IS NULL');
    if(this.getItem(itemId)?.kind!=='image')return this.one<ThreadRow>('SELECT * FROM threads WHERE item_id=?',itemId);
    const root=this.imageRoot(itemId);
    // Existing releases may have forked conversations at different revisions.
    // Prefer a root thread, otherwise the earliest family thread, without moving
    // or deleting any historical conversation. UNION bounds corrupt cycles.
    return this.one<ThreadRow>(`WITH RECURSIVE family(id) AS (
      SELECT ? UNION SELECT child.id FROM items child JOIN family parent ON json_extract(child.data,'$.previousVersionId')=parent.id WHERE child.kind='image'
    ) SELECT * FROM threads WHERE item_id IN (SELECT id FROM family) ORDER BY CASE WHEN item_id=? THEN 0 ELSE 1 END,created_at,id LIMIT 1`,root,root);
  }
  private message(row:MessageRow){return{id:row.id,threadId:row.thread_id,userId:row.user_id,name:row.name,body:row.body,replyToId:row.reply_to_id,attachments:JSON.parse(row.attachments),mentionedUserIds:JSON.parse(row.mentioned_user_ids),at:row.at};}
  // The team owner is authoritative even when a legacy team lacks its owner
  // membership row. The picker exposes display names/roles, never email/session data.
  private async projectMembers(projectId:string,after='',query='',limit=201,onlyIds?:string[]){
    const selected=onlyIds?' AND id IN (SELECT value FROM json_each(?))':'';
    const statement=this.env.DB.prepare(`WITH project_members AS (
      SELECT u.id,u.name,'owner' role FROM projects p LEFT JOIN teams t ON t.id=p.team_id JOIN users u ON u.id=COALESCE(t.owner_id,p.owner_id) WHERE p.id=? AND p.archived_at IS NULL
      UNION ALL
      SELECT u.id,u.name,m.role FROM projects p JOIN teams t ON t.id=p.team_id JOIN team_members m ON m.team_id=t.id JOIN users u ON u.id=m.user_id WHERE p.id=? AND p.archived_at IS NULL AND u.id<>t.owner_id
    ) SELECT id,name,role FROM project_members WHERE id>? AND instr(lower(name),lower(?))>0${selected} ORDER BY id LIMIT ?`);
    const values:(string|number)[]=[projectId,projectId,after,query];if(onlyIds)values.push(JSON.stringify(onlyIds));values.push(limit);
    return(await statement.bind(...values).all<{id:string;name:string;role:string}>()).results;
  }
  private event(row:EventRow):ProjectEvent {
    const data=JSON.parse(row.data);const skip=data.snapshotRequired===true;
    const changes=skip?[]:this.rows<{item_id:string;before_json:string|null;after_json:string}>('SELECT item_id,before_json,after_json FROM changes WHERE seq=? ORDER BY item_id',row.seq).map(c=>({id:c.item_id,before:c.before_json?JSON.parse(c.before_json):null,after:JSON.parse(c.after_json)}));
    return{seq:row.seq,epoch:row.epoch,commandId:row.command_id,actorId:row.actor_id,kind:row.kind,at:row.at,changes,data};
  }
  private eventPage(after:number,limit=100){
    const state=this.state(),rows=this.rows<EventRow>('SELECT * FROM events WHERE seq>? ORDER BY seq LIMIT ?',after,limit),events:ProjectEvent[]=[];
    let bytes=0;
    for(const row of rows){
      let event=this.event(row),size=new TextEncoder().encode(JSON.stringify(event)).byteLength;
      // HTTP and WebSocket replay share the same bounded envelope. A journal
      // entry can include large before/after payloads even for a small delete
      // command; don't construct an unbounded 200-event response in memory.
      if(size>262144){event={...event,changes:[],data:{...event.data,snapshotRequired:true}};size=new TextEncoder().encode(JSON.stringify(event)).byteLength;}
      if(events.length&&bytes+size>524288)break;
      events.push(event);bytes+=size;
    }
    return{events,headSeq:state.head_seq,epoch:state.epoch,timingVersion:state.timing_version,hasMore:(events.at(-1)?.seq??after)<state.head_seq};
  }
  private broadcast(value:unknown,except?:WebSocket){const text=JSON.stringify(value);for(const socket of this.ctx.getWebSockets()){if(socket===except||socket.readyState!==WebSocket.OPEN)continue;const a=socket.deserializeAttachment() as Attachment;if(a.expiresAt<=Date.now()||a.premiumUntil<=Date.now()){try{socket.close(4001,'Access expired');}catch{}continue;}try{socket.send(text);}catch{try{socket.close(1011,'Connection lost');}catch{}}}}
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
  private putItem(item:Item){const d=item.data;this.sql.exec(`INSERT INTO items(id,kind,version,data,deleted,scene_id,ordinal,start_ms,end_ms,duration_ms) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,version=excluded.version,data=excluded.data,deleted=excluded.deleted,scene_id=excluded.scene_id,ordinal=excluded.ordinal,start_ms=excluded.start_ms,end_ms=excluded.end_ms,duration_ms=excluded.duration_ms`,item.id,item.kind,item.version,JSON.stringify(d),item.deleted?1:0,typeof d.sceneId==='string'?d.sceneId:null,typeof d.order==='number'?d.order:null,typeof d.startMs==='number'?d.startMs:null,typeof d.endMs==='number'?d.endMs:null,typeof d.ownedDurationMs==='number'?d.ownedDurationMs:null);
    if(item.kind==='entry'){
      this.sql.exec('DELETE FROM word_owners WHERE item_id=?',item.id);
      if(!item.deleted)this.sql.exec(`INSERT INTO word_owners(word_id,item_id) SELECT json_extract(value,'$.id'),? FROM json_each(?)`,item.id,JSON.stringify(d.words));
    }
  }
  private requireLease(itemId:string,lease:Operation['lease'],sessionId:string,identity:Identity,epoch:number){
    const row=this.one<LeaseRow>('SELECT * FROM leases WHERE item_id=?',itemId);
    assert(row&&lease&&row.token===lease.token&&row.fence===lease.fence&&row.user_id===identity.user.id&&row.auth_session_id===identity.sessionId&&row.session_id===sessionId&&row.epoch===epoch&&row.expires_at>Date.now(),423,'lease_required','Acquire or renew the item edit lease before saving.',{itemId,owner:row&&row.expires_at>Date.now()?{userId:row.user_id,name:row.name,expiresAt:row.expires_at}:null});
  }
  private validateReferences(changes:Change[]){
    const scenes=new Set<string>();
    const reference=(value:unknown,kind:ItemKind,name:string)=>{if(value===undefined||value===null)return;const target=this.getItem(String(value));assert(target&&!target.deleted&&target.kind===kind,400,'invalid_reference',`${name} refers to an unavailable ${kind}.`);};
    for(const change of changes){const item=change.after,d=item.data;
      // Text, word timings, labels and appearance do not alter scene geometry.
      // Keep their per-item/reference checks below without scanning every cue.
      const geometryKeys=item.kind==='entry'?['sceneId','order','kind','ownedDurationMs','coverageDurationMs']:item.kind==='cue'?['sceneId','startMs','endMs','startAnchor','authoredDurationMs']:item.kind==='scene'?['order']:null;
      if(geometryKeys&&(!change.before||change.before.deleted!==item.deleted||geometryKeys.some(key=>change.before!.data[key]!==d[key]))){
        if(change.before?.data.sceneId)scenes.add(String(change.before.data.sceneId));
        if(d.sceneId)scenes.add(String(d.sceneId));
        if(item.kind==='scene')scenes.add(item.id);
      }
      if(!item.deleted){
        if(item.kind==='entry'){
          reference(d.sceneId,'scene','sceneId');reference(d.characterId,'character','characterId');
          for(const link of (d.characterLinks??[]) as {characterId?:string|null}[])reference(link.characterId,'character','characterLinks.characterId');
          assert(!this.one('SELECT word_id FROM word_owners WHERE word_id IN (SELECT word_id FROM word_owners WHERE item_id=?) GROUP BY word_id HAVING COUNT(*)>1 LIMIT 1',item.id),400,'duplicate_word','Word IDs must be unique throughout the project.');
        }
        if(item.kind==='cue'){reference(d.sceneId,'scene','sceneId');reference(d.imageId,'image','imageId');}
        if(item.kind==='image'){
          for(const ref of d.characterIds as string[])reference(ref,'character','characterIds');reference(d.previousVersionId,'image','previousVersionId');
          if(d.previousVersionId){const previous=this.getItem(String(d.previousVersionId))!;assert(previous.id!==item.id&&Number(d.version)>Number(previous.data.version),400,'image_version','An image revision must follow its previous version without cycles.');}
        }
        if(item.kind==='character')reference(d.portraitImageId,'image','portraitImageId');
      } else {
        if(item.kind==='scene')assert(!this.one('SELECT id FROM items WHERE scene_id=? AND deleted=0 LIMIT 1',item.id),409,'item_in_use','Delete the scene contents in the same command before deleting the scene.');
        if(item.kind==='character')assert(!this.one(`SELECT id FROM items WHERE deleted=0 AND ((kind='entry' AND (json_extract(data,'$.characterId')=? OR EXISTS(SELECT 1 FROM json_each(items.data,'$.characterLinks') WHERE json_extract(value,'$.characterId')=?))) OR (kind='image' AND EXISTS(SELECT 1 FROM json_each(items.data,'$.characterIds') WHERE value=?))) LIMIT 1`,item.id,item.id,item.id),409,'item_in_use','Remove character links and image tags in the same command before deleting this character.');
        if(item.kind==='image')assert(!this.one(`SELECT id FROM items WHERE deleted=0 AND ((kind='cue' AND json_extract(data,'$.imageId')=?) OR (kind='character' AND json_extract(data,'$.portraitImageId')=?) OR (kind='image' AND json_extract(data,'$.previousVersionId')=?)) LIMIT 1`,item.id,item.id,item.id),409,'item_in_use','This image version is still referenced. Remove its references first.');
      }
    }
    for(const sceneId of scenes){
      const entries=this.rows<{id:string;duration_ms:number;entry_kind:string}>("SELECT id,duration_ms,json_extract(data,'$.kind') entry_kind FROM items WHERE scene_id=? AND kind=? AND deleted=0 ORDER BY ordinal,id",sceneId,'entry');
      let duration=0;const starts=new Map<string,{start:number;duration:number;kind:string}>();
      for(const entry of entries){starts.set(entry.id,{start:duration,duration:entry.duration_ms,kind:entry.entry_kind});duration+=entry.duration_ms;}
      assert(duration<=86400000,400,'scene_too_long','A scene cannot exceed 24 hours.');
      const cues=this.rows<{start_ms:number;end_ms:number;data:string}>('SELECT start_ms,end_ms,data FROM items WHERE scene_id=? AND kind=? AND deleted=0 ORDER BY start_ms,id',sceneId,'cue');
      let previousEnd=0,legacyEnd=0;
      for(const cue of cues){
        const data=JSON.parse(cue.data),anchor=data.startAnchor as {entryId:string;offsetMs:number}|undefined;
        assert(cue.end_ms<=duration,409,'cue_timing','Image cues must remain inside their scene. Resize related cues in the same atomic command.');
        if(anchor){
          const source=starts.get(anchor.entryId);
          // A zero-owned direction at the exact scene tail may retain dormant
          // positive authored coverage. The exact clamp below is the only case
          // where resolved start==end is valid; it reappears with later content.
          assert(source&&((source.duration>0&&anchor.offsetMs<source.duration)||(source.kind==='direction'&&source.duration===0&&anchor.offsetMs===0))&&cue.start_ms===source.start+anchor.offsetMs&&cue.end_ms===Math.min(duration,cue.start_ms+Number(data.authoredDurationMs)),409,'cue_anchor','Image coverage must resolve from its source entry and authored duration.');
          assert(cue.start_ms>=legacyEnd,409,'cue_timing','Migrate overlapping legacy image cues to source anchors in the same edit.');
        }else{
          assert(cue.start_ms>=previousEnd,409,'cue_timing','Legacy image cues must not overlap. Migrate their source anchors in the same edit.');legacyEnd=cue.end_ms;
        }
        previousEnd=Math.max(previousEnd,cue.end_ms);
      }
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
  private commit(identity:Identity,command:Command,hash:string,snapshotRequired=false,atomicLeases=false){
    return this.ctx.storage.transactionSync(()=>{
      const previous=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',command.commandId);
      if(previous){assert(previous.user_id===identity.user.id&&previous.request_hash===hash,409,'command_reused','A command ID cannot be reused for a different change.');return{receipt:JSON.parse(previous.result),event:null};}
      const state=this.state();assert(command.epoch===state.epoch,409,'stale_epoch','The project was restored. Refresh it before editing.',{epoch:state.epoch});
      const timingKeys=['sceneId','order','kind','ownedDurationMs','coverageDurationMs','text','words'];
      const touchesTiming=command.operations.some(operation=>{const prior=this.getItem(operation.id),kind=operation.kind??prior?.kind;if(kind!=='entry'&&kind!=='cue')return false;if(!prior||prior.deleted||operation.op==='delete')return true;const keys=kind==='entry'?timingKeys:['sceneId','startMs','endMs','startAnchor','authoredDurationMs'];return keys.some(key=>stableJSON(prior.data[key])!==stableJSON(operation.data?.[key]));});
      const changesTimeline=command.operations.some(operation=>{const prior=this.getItem(operation.id),kind=operation.kind??prior?.kind;if(kind!=='entry'&&kind!=='cue')return false;if(!prior||prior.deleted||operation.op==='delete')return true;const keys=kind==='entry'?['sceneId','order','kind','ownedDurationMs','coverageDurationMs']:['sceneId','startMs','endMs','startAnchor','authoredDurationMs'];return keys.some(key=>stableJSON(prior.data[key])!==stableJSON(operation.data?.[key]));});
      if(changesTimeline)assert(command.expectedTimingVersion===state.timing_version,409,'timing_conflict','The project timing changed. Refresh and reapply this edit.',{timingVersion:state.timing_version});
      const timingVersion=state.timing_version+(touchesTiming?1:0);
      const changes:Change[]=[];let changeBytes=0;const temporaryLeases:string[]=[];
      for(const operation of command.operations){const existing=this.getItem(operation.id);assert((existing?.version??0)===operation.expectedVersion,409,'version_conflict','This item changed on another device.',{itemId:operation.id,current:existing});if(existing){
          if(atomicLeases&&!operation.lease){
            const current=this.one<LeaseRow>('SELECT * FROM leases WHERE item_id=?',operation.id),now=Date.now();
            if(current&&current.expires_at>now&&current.epoch===state.epoch){
              assert(current.user_id===identity.user.id&&current.auth_session_id===identity.sessionId&&current.session_id===command.sessionId,423,'item_locked',`${current.name} is editing this item.`,{itemId:operation.id});
              operation.lease={token:current.token,fence:current.fence};
            }else{
              const token=randomToken(),fence=(current?.fence??0)+1;
              this.sql.exec(`INSERT INTO leases(item_id,auth_session_id,session_id,token,fence,expires_at,epoch,user_id,name) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET auth_session_id=excluded.auth_session_id,session_id=excluded.session_id,token=excluded.token,fence=excluded.fence,expires_at=excluded.expires_at,epoch=excluded.epoch,user_id=excluded.user_id,name=excluded.name`,operation.id,identity.sessionId,command.sessionId,token,fence,now+30000,state.epoch,identity.user.id,identity.user.name);
              operation.lease={token,fence};temporaryLeases.push(operation.id);
            }
          }
          this.requireLease(operation.id,operation.lease,command.sessionId,identity,state.epoch);
        }
        assert(operation.op!=='delete'||(existing&&!existing.deleted),404,'not_found','The item no longer exists.');assert(!existing||operation.kind===undefined||operation.kind===existing.kind,409,'kind_conflict','An item cannot change kind.');
        if(existing?.kind==='entry'&&operation.op==='put'&&Array.isArray(existing.data.characterLinks))assert(Array.isArray(operation.data?.characterLinks),409,'schema_upgrade_required','This edit would remove saved character links. Update Scriv and reload the project before retrying.');
        if(existing?.kind==='cue'&&operation.op==='put'&&existing.data.startAnchor!=null)assert(operation.data?.startAnchor!=null&&operation.data?.authoredDurationMs!=null,409,'schema_upgrade_required','This edit would remove saved image source anchors. Update Scriv and reload the project before retrying.');
        if(existing?.kind==='entry'&&operation.op==='put'){
          const nextWords=new Map((operation.data!.words as {id:string;timingSource?:string|null}[]).map(word=>[word.id,word]));
          for(const word of existing.data.words as {id:string;timingSource?:string|null}[])if(word.timingSource==='authored'&&nextWords.has(word.id))assert(nextWords.get(word.id)!.timingSource==='authored',409,'schema_upgrade_required','This edit would remove authored word timing. Update Scriv and reload the project before retrying.');
        }
        if(existing?.kind==='image'&&operation.op==='put')for(const key of ['version','fileName','sha256','mimeType','byteCount','createdAt','previousVersionId'])assert(stableJSON(existing.data[key]??null)===stableJSON(operation.data?.[key]??null),409,'immutable_image','Image bytes and version lineage are immutable. Create a new image version instead.');
        const after:Item={id:operation.id,kind:operation.kind??existing!.kind,version:(existing?.version??0)+1,data:operation.data??existing!.data,deleted:operation.op==='delete'};if(atomicLeases){changeBytes+=new TextEncoder().encode(JSON.stringify(existing)).byteLength+new TextEncoder().encode(JSON.stringify(after)).byteLength;assert(changeBytes<=batchLimits.bytes,413,'batch_history_too_large','This edit exceeds the 16 MiB atomic before/after history budget.');}
        this.putItem(after);changes.push({id:operation.id,before:existing,after});
      }
      this.validateReferences(changes);
      for(const itemId of temporaryLeases)this.sql.exec('UPDATE leases SET expires_at=0 WHERE item_id=?',itemId);
      const itemCount=this.one<{n:number}>('SELECT COUNT(*) n FROM items WHERE deleted=0')!.n;assert(itemCount<=50000,413,'project_limit','A project cannot contain more than 50,000 items. Split it into multiple projects.');
      const seq=state.head_seq+1,at=Date.now();const event:ProjectEvent={seq,epoch:state.epoch,commandId:command.commandId,actorId:identity.user.id,kind:'command',at,changes:snapshotRequired?[]:changes,data:{label:command.label,timingVersion,...(snapshotRequired?{snapshotRequired:true}:{})}};
      this.sql.exec('UPDATE meta SET head_seq=?,timing_version=? WHERE id=1',seq,timingVersion);this.sql.exec('INSERT INTO events(seq,epoch,command_id,actor_id,kind,at,data) VALUES(?,?,?,?,?,?,?)',seq,state.epoch,command.commandId,identity.user.id,event.kind,at,JSON.stringify(event.data));
      for(const c of changes)this.sql.exec('INSERT INTO changes(seq,item_id,before_json,after_json) VALUES(?,?,?,?)',seq,c.id,c.before?JSON.stringify(c.before):null,JSON.stringify(c.after));
      const receipt={commandId:command.commandId,seq,epoch:state.epoch,timingVersion,items:snapshotRequired?[]:changes.map(c=>c.after),...(snapshotRequired?{snapshotRequired:true}:{})};
      this.sql.exec('INSERT INTO receipts(command_id,user_id,request_hash,result) VALUES(?,?,?,?)',command.commandId,identity.user.id,hash,JSON.stringify(receipt));
      return{receipt,event};
    });
  }
  private historicalItems(seq:number,after='',limit=-1):Item[]{
    return this.rows<{after_json:string}>(`SELECT c.after_json FROM changes c JOIN (SELECT item_id,MAX(seq) seq FROM changes WHERE seq<=? AND item_id>? GROUP BY item_id) latest ON latest.item_id=c.item_id AND latest.seq=c.seq ORDER BY c.item_id LIMIT ?`,seq,after,limit).map(row=>JSON.parse(row.after_json) as Item);
  }
  private historicalSnapshot(url:URL,projectId:string):Response{
    const state=this.state(),seq=int(Number(url.searchParams.get('seq')),'seq',0,state.head_seq),limit=int(Number(url.searchParams.get('limit')??200),'limit',1,200),after=url.searchParams.get('after')??'';
    if(after)id(after,'after');
    const row=this.one<EventRow>('SELECT * FROM events WHERE seq<=? ORDER BY seq DESC LIMIT 1',seq),epoch=row?.epoch??1,timingVersion=row?Number(JSON.parse(row.data).timingVersion??0):0;
    if(url.searchParams.has('epoch'))assert(int(Number(url.searchParams.get('epoch')),'epoch',1)===epoch,409,'history_epoch_mismatch','The requested history epoch does not match this sequence.',{epoch});
    const rows=this.historicalItems(seq,after,limit+1),page:Item[]=[];let bytes=0;
    for(const item of rows.slice(0,limit)){
      const projected=item.deleted?{...item,data:{}}:item,size=new TextEncoder().encode(JSON.stringify(projected)).byteLength;
      if(page.length&&bytes+size>524288)break;
      page.push(projected);bytes+=size;
    }
    const hasMore=page.length<rows.length;
    return json({projectId,epoch,headSeq:seq,timingVersion,items:page.filter(item=>!item.deleted),deletedItems:page.filter(item=>item.deleted),canImport:false,threads:[],leases:[],hasMore,nextCursor:hasMore?page.at(-1)!.id:null,historyEvent:row?{seq:row.seq,epoch:row.epoch,actorId:row.actor_id,kind:row.kind,at:row.at}:null});
  }
  private restore(identity:Identity,input:Record<string,unknown>,hash:string){
    const commandId=id(input.commandId,'commandId');id(input.sessionId,'sessionId');const epoch=int(input.epoch,'epoch',1),targetSeq=int(input.seq,'seq');
    return this.ctx.storage.transactionSync(()=>{
      const previous=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',commandId);
      if(previous){assert(previous.user_id===identity.user.id&&previous.request_hash===hash,409,'command_reused','Command ID already used.');return{receipt:JSON.parse(previous.result),event:null};}
      const state=this.state();assert(epoch===state.epoch,409,'stale_epoch','Refresh the project before restoring.');assert(targetSeq<=state.head_seq,400,'invalid_sequence','History sequence is beyond the project head.');
      const historical=this.historicalItems(targetSeq);
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
  // Called inside the same SQLite transaction as its discussion mutation. Chat
  // uses the content journal's sequence/watermark, but never changes item state
  // or timing. Restores intentionally leave threads and messages untouched.
  private discussionEvent(identity:Identity,kind:string,data:Record<string,unknown>):ProjectEvent{
    const state=this.state(),seq=state.head_seq+1,at=Date.now(),commandId=uuid();
    const event:ProjectEvent={seq,epoch:state.epoch,commandId,actorId:identity.user.id,kind,at,changes:[],data:{...data,timingVersion:state.timing_version}};
    this.sql.exec('UPDATE meta SET head_seq=? WHERE id=1',seq);
    this.sql.exec('INSERT INTO events(seq,epoch,command_id,actor_id,kind,at,data) VALUES(?,?,?,?,?,?,?)',seq,state.epoch,commandId,identity.user.id,kind,at,JSON.stringify(event.data));
    return event;
  }
  async fetch(request:Request):Promise<Response>{
    try{
      const authorizationGeneration=this.accessGeneration;
      const url=new URL(request.url);const match=/^\/v1\/projects\/([^/]+)\/(.*)$/.exec(url.pathname);assert(match,404,'not_found','Project route not found.');
      const projectId=id(match[1]),route=match[2]!,identity=await authenticate(request,this.env),access=await projectAccess(this.env,projectId,identity.user.id);
      this.requireCurrentAccess(authorizationGeneration);
      this.sql.exec('INSERT OR IGNORE INTO meta(id,project_id) VALUES(1,?)',projectId);assert(this.state().project_id===projectId,409,'project_identity','Incorrect project room.');
      if(route==='socket'&&request.method==='GET')return this.upgradeSocket(request,identity,access);
      if(route==='snapshot'&&request.method==='GET'){
        if(url.searchParams.has('seq'))return this.historicalSnapshot(url,projectId);
        const state=this.state(),items=this.allItems();
        // Clients need tombstone versions to reacquire a lease and undo a
        // deletion after reconnect. Do not include the deleted content itself.
        const deletedItems=this.rows<{id:string;kind:ItemKind;version:number}>('SELECT id,kind,version FROM items WHERE deleted=1 ORDER BY kind,id').map(item=>({...item,data:{},deleted:true}));
        return json({projectId,epoch:state.epoch,headSeq:state.head_seq,timingVersion:state.timing_version,items,deletedItems,canImport:items.length===0&&deletedItems.length===0,threads:this.rows<ThreadRow>('SELECT * FROM threads ORDER BY updated_at DESC').map(t=>this.thread(t)),leases:this.publicLeases()});
      }
      if(route==='members'&&request.method==='GET'){
        const after=url.searchParams.get('after')??'',query=str(url.searchParams.get('q')??'','q',100,0),limit=int(Number(url.searchParams.get('limit')??100),'limit',1,200);
        if(after)id(after,'after');
        const rows=await this.projectMembers(projectId,after,query,limit+1);
        this.requireCurrentAccess(authorizationGeneration);
        const members=rows.slice(0,limit),hasMore=rows.length>limit;
        return json({members,hasMore,nextCursor:hasMore?members.at(-1)!.id:null});
      }
      if((route==='events'||route==='history')&&request.method==='GET'){const after=int(Number(url.searchParams.get('after')??0),'after'),limit=int(Number(url.searchParams.get('limit')??100),'limit',1,200);return json(this.eventPage(after,limit));}
      if(route==='import'&&request.method==='POST'){
        const raw=await body(request,16*1024*1024);assert(Array.isArray(raw.items)&&raw.items.length>0,400,'invalid_import','Import must contain project items.');
        const command=this.parseCommand({...raw,label:raw.label??'Import project',operations:raw.items.map(value=>{const item=record(value,'item');return{op:'put',id:item.id,kind:item.kind,data:item.data,expectedVersion:0};})},10000);
        const hash=await sha256(stableJSON(raw));this.requireCurrentAccess(authorizationGeneration);const cached=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',command.commandId);
        if(cached){assert(cached.user_id===identity.user.id&&cached.request_hash===hash,409,'command_reused','Command ID already used.');return json(JSON.parse(cached.result));}
        assert(access.canWrite,403,'read_only','You cannot import into this project.');assert(!this.one('SELECT id FROM items LIMIT 1'),409,'project_not_empty','Atomic import is only available for a new empty project.');
        this.requireCurrentAccess(authorizationGeneration);const {receipt,event}=this.commit(identity,command,hash,true);if(event)this.queueEvent(event);return json(receipt);
      }
      if(route==='commands'&&request.method==='POST'){
        const raw=await body(request);const command=this.parseCommand(raw),hash=await sha256(stableJSON(raw));
        this.requireCurrentAccess(authorizationGeneration);
        const cached=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',command.commandId);
        if(cached){assert(cached.user_id===identity.user.id&&cached.request_hash===hash,409,'command_reused','Command ID already used.');return json(JSON.parse(cached.result));}
        assert(access.canWrite,403,'read_only','You can read this project but cannot edit it.');
        this.requireCurrentAccess(authorizationGeneration);const {receipt,event}=this.commit(identity,command,hash);if(event)this.queueEvent(event);return json(receipt);
      }
      if(route==='batches'||route.startsWith('batches/'))return await this.handleBatch(request,route,identity,access,authorizationGeneration);
      if(route==='restore'&&request.method==='POST'){
        const raw=await body(request,8192),hash=await sha256(stableJSON(raw));
        this.requireCurrentAccess(authorizationGeneration);
        const cached=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',id(raw.commandId,'commandId'));
        if(cached){assert(cached.user_id===identity.user.id&&cached.request_hash===hash,409,'command_reused','Command ID already used.');return json(JSON.parse(cached.result));}
        assert(access.canManage&&access.canWrite,403,'not_allowed','Only an owner or administrator can restore history.');
        this.requireCurrentAccess(authorizationGeneration);const {receipt,event}=this.restore(identity,raw,hash);if(event){this.queueEvent(event);this.broadcast({type:'leases',leases:[]});}return json(receipt);
      }
      if(route==='leases')return await this.handleLeases(request,identity,access,authorizationGeneration);
      if(route==='threads'||route.startsWith('threads/'))return await this.handleDiscussion(request,route,identity,access,authorizationGeneration);
      if(route==='signals')return await this.handleSignals(request,identity,access,authorizationGeneration);
      throw new APIError(404,'not_found','Project route not found.');
    }catch(error){return failure(error);}
  }
  private discardBatch(commandId:string){this.sql.exec('DELETE FROM command_batch_parts WHERE command_id=?',commandId);this.sql.exec('DELETE FROM command_batches WHERE command_id=?',commandId);}
  async alarm(){
    this.cleanBatches();const next=this.one<{at:number|null}>('SELECT MIN(expires_at) at FROM command_batches')?.at;
    if(next!==null&&next!==undefined)await this.ctx.storage.setAlarm(next);
  }
  private cleanBatches(){
    const now=Date.now();
    this.sql.exec('DELETE FROM command_batch_parts WHERE command_id IN (SELECT command_id FROM command_batches WHERE expires_at<=?)',now);
    this.sql.exec('DELETE FROM command_batches WHERE expires_at<=?',now);
  }
  private batchReceipt(commandId:string,userId:string,hash:string){
    const prior=this.one<{user_id:string;request_hash:string;result:string}>('SELECT * FROM receipts WHERE command_id=?',commandId);
    if(!prior)return null;
    assert(prior.user_id===userId&&prior.request_hash===hash,409,'command_reused','A command ID cannot be reused for a different change.');
    return JSON.parse(prior.result);
  }
  private async handleBatch(request:Request,route:string,identity:Identity,access:ProjectAccess,authorizationGeneration:number):Promise<Response>{
    const match=/^batches(?:\/([^/]+)\/(commit|parts\/(\d+)))?$/.exec(route);assert(match,404,'not_found','Batch route not found.');
    if(route==='batches'||match[2]==='commit'){
      assert(request.method==='POST',405,'method_not_allowed','Use POST for batch preparation or commit.');
      const manifest=batchManifest(await body(request,192*1024)),hash='batch:'+await sha256(stableJSON(manifest));
      if(match[1])assert(id(match[1])===manifest.commandId,400,'batch_identity','Batch identity does not match its manifest.');
      this.requireCurrentAccess(authorizationGeneration);
      // A lost success remains recoverable after entitlement/leases/epoch change.
      const accepted=this.batchReceipt(manifest.commandId,identity.user.id,hash);if(accepted)return json(accepted);
      assert(access.canWrite,403,'read_only','You can read this project but cannot edit it.');
      this.cleanBatches();
      const existing=this.one<BatchRow>('SELECT * FROM command_batches WHERE command_id=?',manifest.commandId);
      if(existing){
        assert(existing.user_id===identity.user.id&&existing.request_hash===hash,409,'command_reused','A batch ID cannot be reused for a different edit.');
        if(existing.auth_session_id!==identity.sessionId){this.discardBatch(manifest.commandId);throw new APIError(409,'batch_session_changed','Sign-in changed before this edit committed. Reconcile your saved draft before retrying.');}
      }
      if(route==='batches'){
        if(!existing){
          const reserved=manifest.parts.reduce((n,p)=>n+p.bytes,0),room=this.one<{n:number;bytes:number}>('SELECT COUNT(*) n,COALESCE(SUM(reserved_bytes),0) bytes FROM command_batches')!;
          assert(room.n<64&&room.bytes+reserved<=batchLimits.roomBytes,429,'batch_capacity','Too many structural edits are uploading. Retry shortly.');
          assert(this.one<{n:number}>('SELECT COUNT(*) n FROM command_batches WHERE user_id=?',identity.user.id)!.n<2,429,'batch_capacity','Finish or retry your pending structural edit first.');
          this.sql.exec('INSERT INTO command_batches(command_id,user_id,auth_session_id,request_hash,manifest,reserved_bytes,expires_at) VALUES(?,?,?,?,?,?,?)',manifest.commandId,identity.user.id,identity.sessionId,hash,JSON.stringify(manifest),reserved,Date.now()+batchLimits.ttl);
        }
        await this.ctx.storage.setAlarm(this.one<{at:number}>('SELECT MIN(expires_at) at FROM command_batches')!.at);
        return json({commandId:manifest.commandId,staged:true});
      }
      assert(existing,409,'batch_incomplete','Upload all parts before committing the edit.');
      const parts=this.rows<{part_index:number;content:string}>('SELECT part_index,content FROM command_batch_parts WHERE command_id=? ORDER BY part_index',manifest.commandId);
      assert(parts.length===manifest.parts.length&&parts.every((p,i)=>p.part_index===i),409,'batch_incomplete','Upload all parts before committing the edit.');
      const operations=parts.flatMap(part=>JSON.parse(part.content) as unknown[]);
      const command=this.parseCommand({...manifest,operations},batchLimits.operations);
      assert(command.operations.length===manifest.operationCount,400,'invalid_batch','The complete edit has the wrong operation count.');
      this.requireCurrentAccess(authorizationGeneration);
      try{
        const {receipt,event}=this.ctx.storage.transactionSync(()=>{
          const result=this.commit(identity,command,hash,true,true);
          this.discardBatch(manifest.commandId);return result;
        });
        if(event)this.queueEvent(event);return json(receipt);
      }catch(error){
        // The transaction rolled back completely. Do not leave rejected edits
        // reserving upload capacity while the client reconciles a fresh command.
        if(error instanceof APIError)this.discardBatch(manifest.commandId);
        throw error;
      }
    }
    assert(request.method==='PUT',405,'method_not_allowed','Use PUT to upload a batch part.');
    const commandId=id(match[1]),index=int(Number(match[3]),'partIndex',0,batchLimits.parts-1),raw=await body(request,1024*1024),content=str(raw.content,'content',batchLimits.partBytes,2),hash=await sha256(content);
    this.requireCurrentAccess(authorizationGeneration);assert(access.canWrite,403,'read_only','You cannot upload edits to this project.');this.cleanBatches();
    const staged=this.one<BatchRow>('SELECT * FROM command_batches WHERE command_id=?',commandId);assert(staged,409,'batch_incomplete','Prepare the batch before uploading parts.');
    assert(staged.user_id===identity.user.id&&staged.auth_session_id===identity.sessionId,409,'batch_session_changed','This upload belongs to a different sign-in session.');
    const manifest=JSON.parse(staged.manifest) as BatchManifest,expected=manifest.parts[index];
    assert(expected&&expected.hash===hash&&expected.bytes===new TextEncoder().encode(content).byteLength,400,'batch_part_mismatch','Part bytes do not match the immutable edit manifest.');
    let operations:unknown;try{operations=JSON.parse(content);}catch{throw new APIError(400,'invalid_json','A batch part must contain JSON operations.');}
    assert(Array.isArray(operations)&&operations.length===expected.count,400,'invalid_batch','Part operation count does not match the manifest.');
    this.parseCommand({...manifest,operations},batchLimits.partOperations);
    const previous=this.one<{content:string}>('SELECT content FROM command_batch_parts WHERE command_id=? AND part_index=?',commandId,index);
    assert(!previous||previous.content===content,409,'batch_part_mismatch','A part cannot be replaced by different bytes.');
    this.sql.exec('INSERT OR IGNORE INTO command_batch_parts(command_id,part_index,content) VALUES(?,?,?)',commandId,index,content);
    return json({commandId,partIndex:index,staged:true});
  }
  private async handleLeases(request:Request,identity:Identity,access:ProjectAccess,authorizationGeneration:number):Promise<Response>{
    if(request.method==='GET')return json({leases:this.publicLeases(),epoch:this.state().epoch});
    assert(access.canWrite,403,'read_only','You cannot edit this project.');const raw=await body(request,4096);const itemId=id(raw.itemId,'itemId'),sessionId=id(raw.sessionId,'sessionId');const item=this.getItem(itemId);assert(item,404,'not_found','Item not found.');
    this.requireCurrentAccess(authorizationGeneration);
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
  private async handleDiscussion(request:Request,route:string,identity:Identity,access:ProjectAccess,authorizationGeneration:number):Promise<Response>{
    const url=new URL(request.url),match=/^threads(?:\/([^/]+)(?:\/(messages))?)?$/.exec(route);
    assert(match,404,'not_found','Discussion route not found.');
    const threadId=match[1]?id(match[1]):null;
    if(!threadId){
      if(request.method==='GET'){
        const itemId=url.searchParams.get('itemId'),scope=url.searchParams.get('scope');
        if(scope==='all'){
          assert(!itemId,400,'invalid_scope','List all threads or choose an item, not both.');
          const after=url.searchParams.get('after')??'',limit=int(Number(url.searchParams.get('limit')??100),'limit',1,200);if(after)id(after,'after');
          const rows=this.rows<ThreadRow>('SELECT * FROM threads WHERE id>? ORDER BY id LIMIT ?',after,limit+1),threads=rows.slice(0,limit),hasMore=rows.length>limit;
          return json({threads:threads.map(t=>this.thread(t)),hasMore,nextCursor:hasMore?threads.at(-1)!.id:null});
        }
        assert(scope===null,400,'invalid_scope','Unsupported discussion list scope.');
        const thread=this.canonicalThread(itemId?id(itemId):null);
        return json({threads:thread?[this.thread(thread)]:[]});
      }
      assert(request.method==='POST',405,'method_not_allowed','Unsupported discussion operation.');
      const input=await body(request,8192),selectedItemId=input.itemId?id(input.itemId):null;
      this.requireCurrentAccess(authorizationGeneration);
      const selected=selectedItemId?this.getItem(selectedItemId):null;
      const itemId=selected?.kind==='image'?this.imageRoot(selected.id):selectedItemId;
      const existing=this.canonicalThread(selectedItemId);
      // Finding the canonical thread is also used when reopening a read-only
      // discussion; it is not a new write and remains available during grace.
      if(existing)return json({thread:this.thread(existing)});
      assert(access.canWrite||access.premium,403,'read_only','Discussion is read-only for this inactive team.');
      if(itemId)assert(this.getItem(itemId),404,'not_found','Annotated item not found.');
      const anchor={...(input.anchor?record(input.anchor,'anchor'):{})},now=Date.now(),newId=uuid();
      if(selected?.kind==='image'&&anchor.imageVersionId===undefined)anchor.imageVersionId=selected.id;
      if(anchor.wordIds!==undefined){
        assert(Array.isArray(anchor.wordIds)&&anchor.wordIds.length<=1000,400,'invalid_anchor','A word anchor must contain at most 1,000 word IDs.');
        const target=itemId?this.getItem(itemId):null;
        assert(target?.kind==='entry',400,'invalid_anchor','Word anchors must belong to a script entry.');
        const words=new Set((target.data.words as {id:string}[]).map(word=>word.id));
        const selected=anchor.wordIds.map(word=>id(word,'wordId'));
        assert(new Set(selected).size===selected.length&&selected.every(word=>words.has(word)),400,'invalid_anchor','Anchored words must exist in the annotated item.');
      }
      if(anchor.imageVersionId!==undefined){const version=this.getItem(id(anchor.imageVersionId,'imageVersionId'));assert(version?.kind==='image'&&!version.deleted,400,'invalid_anchor','Anchored image version is unavailable.');if(selected?.kind==='image')assert(this.imageRoot(version.id)===itemId,400,'invalid_anchor','An image discussion anchor must belong to the same image lineage.');}
      this.requireCurrentAccess(authorizationGeneration);
      const {thread,event}=this.ctx.storage.transactionSync(()=>{
        this.sql.exec('INSERT INTO threads(id,item_id,anchor,created_at,updated_at) VALUES(?,?,?,?,?)',newId,itemId,JSON.stringify(anchor),now,now);
        const thread=this.thread(this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',newId)!);
        return{thread,event:this.discussionEvent(identity,'discussion.thread-created',{label:'Start discussion',thread})};
      });
      this.queueEvent(event);this.broadcast({type:'thread',thread});return json({thread},201);
    }
    const existing=this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',threadId);
    assert(existing,404,'not_found','Discussion not found.');
    if(match[2]==='messages'){
      if(request.method==='GET'){
        const after=int(Number(url.searchParams.get('after')??0),'after'),afterId=url.searchParams.get('afterId')??'';
        if(afterId)id(afterId,'afterId');
        const rows=this.rows<MessageRow>('SELECT * FROM messages WHERE thread_id=? AND (at>? OR (at=? AND id>?)) ORDER BY at,id LIMIT 500',threadId,after,after,afterId),last=rows.at(-1);
        return json({messages:rows.map(m=>this.message(m)),hasMore:rows.length===500,nextCursor:last?{at:last.at,id:last.id}:null});
      }
      assert(request.method==='POST',405,'method_not_allowed','Unsupported discussion operation.');
      const raw=await body(request,32768),messageId=id(raw.id,'message.id'),text=str(raw.body,'message.body',8000).trim();
      this.requireCurrentAccess(authorizationGeneration);
      assert(text,400,'empty_message','Enter a message.');
      const reply=raw.replyToId?id(raw.replyToId,'replyToId'):null,attachments=raw.attachments??[];
      assert(Array.isArray(attachments)&&attachments.length<=20,400,'invalid_attachments','Messages accept up to 20 attachments.');
      const mentions=raw.mentionedUserIds===undefined?[]:raw.mentionedUserIds;
      assert(Array.isArray(mentions)&&mentions.length<=20,400,'invalid_mentions','Messages accept up to 20 mentioned members.');
      const mentionedUserIds=mentions.map(value=>id(value,'mentionedUserId')).sort();
      assert(new Set(mentionedUserIds).size===mentionedUserIds.length,400,'invalid_mentions','Mentioned members must be unique.');
      // Return a committed send before current write entitlement or references:
      // loss of the HTTP response must not duplicate chat or strand a retry when
      // an attachment/recipient was removed or the team became read-only.
      const accepted=()=>{
        const cached=this.one<MessageRow>('SELECT * FROM messages WHERE id=?',messageId);if(!cached)return null;
        assert(cached.user_id===identity.user.id&&cached.thread_id===threadId&&cached.body===text&&cached.reply_to_id===reply&&stableJSON(JSON.parse(cached.attachments))===stableJSON(attachments)&&stableJSON(JSON.parse(cached.mentioned_user_ids))===stableJSON(mentionedUserIds),409,'message_reused','Message ID already used.');
        return json({message:this.message(cached)});
      };
      const cached=accepted();if(cached)return cached;
      assert(access.canWrite||access.premium,403,'read_only','Discussion is read-only for this inactive team.');
      if(mentionedUserIds.length){
        const members=await this.projectMembers(access.project.id,'','',20,mentionedUserIds);
        this.requireCurrentAccess(authorizationGeneration);
        // Another request may have committed this exact send during the D1 read.
        const raced=accepted();if(raced)return raced;
        assert(members.length===mentionedUserIds.length,400,'invalid_mentions','Mentioned people must currently belong to this project.');
      }
      for(const value of attachments){
        const attachment=record(value,'attachment'),target=this.getItem(id(attachment.itemId,'attachment.itemId'));
        assert(target&&!target.deleted,404,'not_found','Attachment item not found.');
        if(attachment.imageVersionId){const version=this.getItem(id(attachment.imageVersionId,'imageVersionId'));assert(version?.kind==='image'&&!version.deleted,404,'not_found','Image version not found.');}
      }
      if(reply)assert(this.one('SELECT id FROM messages WHERE id=? AND thread_id=?',reply,threadId),400,'invalid_reply','Reply target must be in this thread.');
      this.requireCurrentAccess(authorizationGeneration);
      const {message,event}=this.ctx.storage.transactionSync(()=>{
        // A monotonic per-thread timestamp makes the public (at,id) cursor safe
        // even when a later send has a lexically smaller UUID in the same ms.
        const last=this.one<{at:number}>('SELECT MAX(at) at FROM messages WHERE thread_id=?',threadId);
        const at=Math.max(Date.now(),(last?.at??0)+1);
        this.sql.exec('INSERT INTO messages(id,thread_id,user_id,name,body,reply_to_id,attachments,mentioned_user_ids,at) VALUES(?,?,?,?,?,?,?,?,?)',messageId,threadId,identity.user.id,identity.user.name,text,reply,JSON.stringify(attachments),JSON.stringify(mentionedUserIds),at);
        this.sql.exec('UPDATE threads SET updated_at=? WHERE id=?',at,threadId);
        const message=this.message(this.one<MessageRow>('SELECT * FROM messages WHERE id=?',messageId)!);
        return{message,event:this.discussionEvent(identity,'discussion.message-created',{label:'Send message',message})};
      });
      this.queueEvent(event);this.broadcast({type:'message',message});return json({message},201);
    }
    if(request.method==='PATCH'){
      assert(access.canWrite||access.premium,403,'read_only','Discussion is read-only.');
      const raw=await body(request,4096);assert(typeof raw.resolved==='boolean',400,'invalid_field','resolved must be a boolean.');
      this.requireCurrentAccess(authorizationGeneration);
      const {thread,event}=this.ctx.storage.transactionSync(()=>{
        const current=this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',threadId)!;
        if(!!current.resolved===raw.resolved)return{thread:this.thread(current),event:null};
        this.sql.exec('UPDATE threads SET resolved=?,updated_at=? WHERE id=?',raw.resolved?1:0,Math.max(Date.now(),current.updated_at+1),threadId);
        const thread=this.thread(this.one<ThreadRow>('SELECT * FROM threads WHERE id=?',threadId)!);
        return{thread,event:this.discussionEvent(identity,'discussion.thread-updated',{label:raw.resolved?'Resolve discussion':'Reopen discussion',thread})};
      });
      if(event){this.queueEvent(event);this.broadcast({type:'thread',thread});}return json({thread});
    }
    if(request.method==='GET')return json({thread:this.thread(existing)});
    throw new APIError(405,'method_not_allowed','Unsupported discussion operation.');
  }
  private async handleSignals(request:Request,identity:Identity,access:ProjectAccess,authorizationGeneration:number):Promise<Response>{
    if(request.method==='GET'){const url=new URL(request.url);const recipient=url.searchParams.get('deviceId')??identity.sessionId;assert(recipient===identity.sessionId,403,'not_allowed','A device can read only its own signaling inbox.');const after=int(Number(url.searchParams.get('after')??0),'after');const rows=this.rows<{id:number;from_device_id:string;from_user_id:string;signal_type:string;payload:string;at:number}>('SELECT * FROM signals WHERE to_device_id=? AND id>? AND expires_at>? ORDER BY id LIMIT 100',recipient,after,Date.now());return json({deviceId:identity.sessionId,signals:rows.map(s=>({id:s.id,fromDeviceId:s.from_device_id,fromUserId:s.from_user_id,type:s.signal_type,payload:JSON.parse(s.payload),at:s.at}))});}
    assert(request.method==='POST',405,'method_not_allowed','Unsupported signaling operation.');const raw=await body(request,65536);await this.routeSignal(raw,identity,access,authorizationGeneration);return json({ok:true});
  }
  private async routeSignal(raw:Record<string,unknown>,identity:Identity,access:ProjectAccess,authorizationGeneration:number){
    const recipient=id(raw.toDeviceId,'toDeviceId');const type=String(raw.signalType??raw.type);assert(['offer','answer','ice','asset-request','asset-available'].includes(type),400,'invalid_signal','Unsupported peer signal.');
    const target=await this.env.DB.prepare('SELECT user_id FROM sessions WHERE id=? AND revoked_at IS NULL AND expires_at>?').bind(recipient,Date.now()).first<{user_id:string}>();assert(target,404,'peer_unavailable','Peer device is unavailable.');
    const other=await projectAccess(this.env,access.project.id,target.user_id);assert(identity.user.id===target.user_id||access.premium&&other.premium,402,'team_subscription_required','Multiplayer peer exchange requires an active Team subscription.');
    const payload=record(raw.payload,'payload'),encoded=JSON.stringify(payload);assert(new TextEncoder().encode(encoded).byteLength<=50000,413,'signal_too_large','Peer signals cannot contain image bytes.');const now=Date.now();
    this.requireCurrentAccess(authorizationGeneration);
    this.sql.exec('DELETE FROM signals WHERE expires_at<?',now);this.sql.exec('INSERT INTO signals(to_device_id,from_device_id,from_user_id,signal_type,payload,at,expires_at) VALUES(?,?,?,?,?,?,?)',recipient,identity.sessionId,identity.user.id,type,encoded,now,now+120000);
    for(const socket of this.ctx.getWebSockets()){const attachment=socket.deserializeAttachment() as Attachment;if(attachment.sessionId===recipient)this.send(socket,{type:'signal',fromDeviceId:identity.sessionId,fromUserId:identity.user.id,signalType:type,payload});}
  }
  private upgradeSocket(request:Request,identity:Identity,access:ProjectAccess):Response {
    assert(request.headers.get('upgrade')?.toLowerCase()==='websocket',426,'websocket_required','Upgrade to WebSocket to join the live project.');assert(access.premium,402,'team_subscription_required','Live multiplayer requires a Team subscription.');
    assert(this.ctx.getWebSockets().filter(socket=>socket.readyState===WebSocket.OPEN).length<1000,503,'room_full','This project currently has too many live connections. Retry shortly.');
    const pair=new WebSocketPair();const client=pair[0],server=pair[1];const connectionId=uuid();
    this.ctx.acceptWebSocket(server);server.serializeAttachment({projectId:access.project.id,userId:identity.user.id,name:identity.user.name,sessionHash:identity.tokenHash,sessionId:identity.sessionId,connectionId,expiresAt:identity.expiresAt,premiumUntil:access.team?.paid_until??0,lastPresenceAt:Date.now(),lastSeenAt:Date.now(),lastMessageAt:Date.now(),messageCount:0,presence:{},...(request.headers.get('X-Scriv-Presence')==='delta-v1'?{presenceProtocol:'delta-v1' as const}:{})} satisfies Attachment);
    const state=this.state();this.send(server,{type:'hello',projectId:access.project.id,epoch:state.epoch,headSeq:state.head_seq,timingVersion:state.timing_version,connectionId,deviceId:identity.sessionId});this.send(server,{type:'leases',leases:this.publicLeases()});this.send(server,{type:'presence',peers:this.peers()});
    this.queuePresenceBroadcast();
    return new Response(null,{status:101,webSocket:client});
  }
  private peers(){const now=Date.now();return this.ctx.getWebSockets().filter(socket=>socket.readyState===WebSocket.OPEN).map(socket=>socket.deserializeAttachment() as Attachment).filter(a=>now-(a.lastSeenAt??a.lastPresenceAt)<30000&&a.expiresAt>now&&a.premiumUntil>now).map(a=>({connectionId:a.connectionId,deviceId:a.sessionId,userId:a.userId,name:a.name,...(a.presence??{}),at:a.lastPresenceAt}));}
  private queuePresenceBroadcast(){
    if(this.presenceFlushScheduled)return;
    this.presenceFlushScheduled=true;
    // One trailing-latest room batch, never one fanout per moving cursor.
    const interval=this.ctx.getWebSockets().length>100?250:200;
    const delay=Math.max(0,interval-(Date.now()-this.lastPresenceBroadcast));
    this.ctx.waitUntil(new Promise<void>(resolve=>setTimeout(resolve,delay)).then(()=>{this.presenceFlushScheduled=false;this.flushPresence();}));
  }
  private flushPresence(){
    this.lastPresenceBroadcast=Date.now();this.lastPresenceSweep=this.lastPresenceBroadcast;
    const peers=this.peers(),baseline=this.publishedPresence,current=new Map<string,string>();
    const changed=peers.filter(peer=>{const {at,...visible}=peer;const fingerprint=JSON.stringify(visible);current.set(peer.connectionId,fingerprint);return baseline?.get(peer.connectionId)!==fingerprint;});
    const removedConnectionIds=baseline?[...baseline.keys()].filter(key=>!current.has(key)):[];
    this.publishedPresence=current;
    if(baseline&&changed.length===0&&removedConnectionIds.length===0)return;
    const snapshot=JSON.stringify({type:'presence',peers});
    const delta=JSON.stringify({type:'presence-delta',peers:changed,removedConnectionIds});
    for(const socket of this.ctx.getWebSockets()){
      if(socket.readyState!==WebSocket.OPEN)continue;
      const a=socket.deserializeAttachment() as Attachment;
      if(a.expiresAt<=Date.now()||a.premiumUntil<=Date.now()){try{socket.close(4001,'Access expired');}catch{}continue;}
      try{socket.send(baseline&&a.presenceProtocol==='delta-v1'?delta:snapshot);}catch{try{socket.close(1011,'Connection lost');}catch{}}
    }
  }
  private async socketIdentity(socket:WebSocket):Promise<{identity:Identity;access:ProjectAccess;attachment:Attachment}>{
    const a=socket.deserializeAttachment() as Attachment;
    const session=await this.env.DB.prepare('SELECT s.id,s.user_id,s.expires_at,u.name,u.email,u.avatar_url FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?').bind(a.sessionHash,Date.now()).first<{id:string;user_id:string;expires_at:number;name:string;email:string|null;avatar_url:string|null}>();
    assert(session,401,'session_expired','Session expired.');const identity:Identity={user:{id:session.user_id,name:session.name,email:session.email,avatarUrl:session.avatar_url},sessionId:session.id,tokenHash:a.sessionHash,expiresAt:session.expires_at};const access=await projectAccess(this.env,a.projectId,session.user_id);assert(access.premium,402,'team_subscription_required','Team subscription is inactive.');return{identity,access,attachment:socket.deserializeAttachment() as Attachment};
  }
  async webSocketMessage(socket:WebSocket,message:string|ArrayBuffer){
    let authorized=false;const authorizationGeneration=this.accessGeneration;
    try{
      // URLSessionWebSocketTask sends JSON .data frames; browsers often send
      // strings. Accept both, bounded by UTF-8 bytes rather than UTF-16 length.
      const bytes=typeof message==='string'?new TextEncoder().encode(message):new Uint8Array(message);
      assert(bytes.byteLength<=65536,413,'message_too_large','Live messages must be JSON up to 64 KiB.');
      let decoded:unknown;
      try{decoded=JSON.parse(new TextDecoder('utf-8',{fatal:true,ignoreBOM:false}).decode(bytes));}
      catch{throw new APIError(400,'invalid_json','Live messages must contain valid UTF-8 JSON.');}
      const raw=record(decoded);const {identity,access,attachment:a}=await this.socketIdentity(socket);this.requireCurrentAccess(authorizationGeneration);authorized=true;
      const now=Date.now();if(now-a.lastMessageAt>1000){a.lastMessageAt=now;a.messageCount=0;}a.messageCount++;assert(a.messageCount<=30,429,'rate_limited','Live messages are arriving too quickly.');a.expiresAt=identity.expiresAt;a.premiumUntil=access.team?.paid_until??0;a.name=identity.user.name;a.lastSeenAt=now;socket.serializeAttachment(a);
      if(raw.type==='resume'){this.flushEvents();this.send(socket,{type:'events',...this.eventPage(int(raw.after??0,'after'),100)});return;}
      if(raw.type==='ping'){this.flushEvents();const state=this.state();this.send(socket,{type:'watermark',headSeq:state.head_seq,epoch:state.epoch,timingVersion:state.timing_version});if(now-this.lastPresenceSweep>=10000||!this.publishedPresence?.has(a.connectionId))this.queuePresenceBroadcast();return;}
      if(raw.type==='presence'){
        const presence:Record<string,unknown>={};if(raw.itemId!==undefined&&raw.itemId!==null){presence.itemId=id(raw.itemId,'itemId');const item=this.getItem(presence.itemId as string);assert(item&&!item.deleted,400,'invalid_presence','Presence item is unavailable; refresh the project.');}
        if(raw.selection){const selection=record(raw.selection,'selection');presence.selection={start:int(selection.start,'selection.start',0,50000),end:int(selection.end,'selection.end',int(selection.start,'selection.start',0,50000),50000)};}
        if(raw.cursor){const cursor=record(raw.cursor,'cursor');assert(typeof cursor.x==='number'&&Number.isFinite(cursor.x)&&typeof cursor.y==='number'&&Number.isFinite(cursor.y),400,'invalid_cursor','Cursor coordinates must be finite.');presence.cursor={x:cursor.x,y:cursor.y};}
        a.presence=presence;a.lastPresenceAt=now;socket.serializeAttachment(a);this.queuePresenceBroadcast();return;
      }
      if(raw.type==='signal'){await this.routeSignal(raw,identity,access,authorizationGeneration);return;}
      throw new APIError(400,'unknown_message','Unsupported live message. Use HTTP commands for durable edits.');
    }catch(error){const code=error instanceof APIError?error.code:'invalid_message';try{this.send(socket,{type:'error',error:{code,message:error instanceof APIError?error.message:'Invalid live message.'}});if(!authorized&&error instanceof APIError&&[401,402,403,404].includes(error.status))socket.close(4001,'Access changed');}catch{}}
  }
  async refreshAccess(userId?:string,sessionId?:string):Promise<void> {
    // Fence requests already authenticated but still reading an upload/body or
    // awaiting a digest/peer lookup. Such requests must not create new items or
    // messages after a removal, downgrade, logout or archive finishes.
    this.accessGeneration++;
    const project=this.one<{project_id:string}>('SELECT project_id FROM meta WHERE id=1');
    let leasesChanged=false;
    if(project){
      const leases=this.rows<LeaseRow>('SELECT * FROM leases WHERE expires_at>?',Date.now()).filter(lease=>(!userId||lease.user_id===userId)&&(!sessionId||lease.auth_session_id===sessionId));
      const permissions=new Map<string,boolean>();
      for(const lease of leases){
        const key=`${lease.user_id}:${lease.auth_session_id}`;
        if(!permissions.has(key)){
          try{
            const session=await this.env.DB.prepare('SELECT id FROM sessions WHERE id=? AND user_id=? AND revoked_at IS NULL AND expires_at>?').bind(lease.auth_session_id,lease.user_id,Date.now()).first();
            const access=session?await projectAccess(this.env,project.project_id,lease.user_id):null;
            permissions.set(key,!!access?.canWrite);
          }catch(error){
            // Transient infrastructure errors must not silently revoke a valid
            // editor. Propagate them so the caller can retry its access refresh.
            if(!(error instanceof APIError)||![401,402,403,404].includes(error.status))throw error;
            permissions.set(key,false);
          }
        }
        if(!permissions.get(key)){
          this.sql.exec('UPDATE leases SET expires_at=0,token=? WHERE item_id=? AND token=? AND fence=?',randomToken(),lease.item_id,lease.token,lease.fence);
          leasesChanged=true;
        }
      }
    }
    for(const socket of this.ctx.getWebSockets()){
      const a=socket.deserializeAttachment() as Attachment;if(userId&&a.userId!==userId)continue;if(sessionId&&a.sessionId!==sessionId)continue;
      try{const {access,identity,attachment:current}=await this.socketIdentity(socket);current.expiresAt=identity.expiresAt;current.premiumUntil=access.team?.paid_until??0;socket.serializeAttachment(current);}
      catch{try{socket.close(4001,'Access changed');}catch{}}
    }
    if(leasesChanged)this.broadcast({type:'leases',leases:this.publicLeases()});
    this.queuePresenceBroadcast();
  }
  async webSocketClose(socket:WebSocket,code:number,reason:string,wasClean:boolean){try{socket.close(code,reason);}catch{}this.queuePresenceBroadcast();}
  async webSocketError(socket:WebSocket){try{socket.close(1011,'Connection error');}catch{}this.queuePresenceBroadcast();}
}
