import { assert, id, int, record, str } from './http';

// Uploads are transport pieces only: no item is changed until one final SQLite
// transaction. Keep whole-edit and per-room budgets independent of HTTP limits.
export const batchLimits = { operations: 10000, bytes: 16 * 1024 * 1024, parts: 1024, partOperations: 100, partBytes: 384 * 1024, roomBytes: 64 * 1024 * 1024, ttl: 24 * 60 * 60 * 1000 } as const;
export interface BatchManifest { commandId:string;sessionId:string;epoch:number;expectedTimingVersion?:number;label:string;operationCount:number;parts:{hash:string;bytes:number;count:number}[] }
export function batchManifest(raw:Record<string,unknown>):BatchManifest {
  const commandId=id(raw.commandId,'commandId'),sessionId=id(raw.sessionId,'sessionId'),epoch=int(raw.epoch,'epoch',1),label=str(raw.label??'Edit','label',200);
  const operationCount=int(raw.operationCount,'operationCount',1,batchLimits.operations);
  assert(Array.isArray(raw.parts)&&raw.parts.length>0&&raw.parts.length<=batchLimits.parts,400,'invalid_batch','A batch must contain bounded upload parts.');
  const parts=raw.parts.map(value=>{const part=record(value,'part'),hash=str(part.hash,'part.hash',64,64);assert(/^[a-f0-9]{64}$/.test(hash),400,'invalid_hash','A part requires a SHA-256 digest.');return{hash,bytes:int(part.bytes,'part.bytes',2,batchLimits.partBytes),count:int(part.count,'part.count',1,batchLimits.partOperations)};});
  assert(parts.reduce((n,p)=>n+p.count,0)===operationCount,400,'invalid_batch','Part operation counts must match the complete edit.');
  assert(parts.reduce((n,p)=>n+p.bytes,0)<=batchLimits.bytes,413,'batch_too_large','An atomic edit cannot exceed 16 MiB.');
  return{commandId,sessionId,epoch,label,operationCount,parts,...(raw.expectedTimingVersion===undefined?{}:{expectedTimingVersion:int(raw.expectedTimingVersion,'expectedTimingVersion')})};
}
