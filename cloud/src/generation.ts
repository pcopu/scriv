import type { Env, Identity } from './types';
import { projectAccess } from './access';
import { assert, body, id, int, json, sha256, stableJSON, str } from './http';

// The server coordinates local work; it never invokes an engine or stores its inputs.
const LEASE_MS = 90_000;
type Status = 'queued' | 'running' | 'waiting' | 'completed' | 'cancelled' | 'failed';
interface JobRow {
  project_id:string; id:string; target_item_id:string; source_revision:number;
  created_by:string; owner_device_id:string; owner_device_name:string; status:Status;
  progress_text:string; version:number; lease_expires_at:number; created_at:number;
  updated_at:number; output_image_id:string|null; error_code:string|null;
  last_operation_id:string|null; owner_live:number;
}
interface Receipt { request_hash:string; actor_session_id:string; resulting_version:number }
const SELECT_JOB = `SELECT j.*,EXISTS(SELECT 1 FROM sessions owner_session
  WHERE owner_session.id=j.owner_device_id AND owner_session.user_id=j.created_by
    AND owner_session.revoked_at IS NULL AND owner_session.expires_at>?) owner_live FROM generation_jobs j`;
// Every mutation linearizes current project authority and the device session with
// its CAS write, after all request-body and hashing awaits. Owners retain solo and
// lapsed-team access, exactly as projectAccess does; lapsed members are read-only.
const WRITE_ACCESS = `EXISTS(SELECT 1 FROM projects p LEFT JOIN teams t ON t.id=p.team_id
  LEFT JOIN team_members actor ON actor.team_id=t.id AND actor.user_id=?
  WHERE p.id=? AND p.archived_at IS NULL AND (
    (p.team_id IS NULL AND p.owner_id=?) OR t.owner_id=? OR
    (t.subscription_status IN ('active','trialing') AND t.paid_until>? AND actor.role IN ('owner','admin','member'))))
  AND EXISTS(SELECT 1 FROM sessions actor_session WHERE actor_session.id=? AND actor_session.user_id=?
    AND actor_session.revoked_at IS NULL AND actor_session.expires_at>?)`;
function accessArgs(identity:Identity, projectId:string, now:number) {
  return [identity.user.id,projectId,identity.user.id,identity.user.id,now,identity.sessionId,identity.user.id,now];
}
function uuid(value:unknown,name:string):string {
  const result=str(value,name,36,36);
  assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(result),400,'invalid_field',`${name} must be a UUID.`);
  return result;
}
function fields(value:Record<string,unknown>,allowed:string[]) {
  assert(Object.keys(value).every(key=>allowed.includes(key)),400,'invalid_field','Only generation job metadata is accepted. Keep prompts, paths and credentials on your Mac.');
}
function view(row:JobRow, now=Date.now()) {
  const waiting=(row.status==='queued'||row.status==='running')&&(!row.owner_live||row.lease_expires_at<=now);
  return {schemaVersion:1,id:row.id,projectId:row.project_id,targetItemId:row.target_item_id,
    sourceRevision:row.source_revision,status:waiting?'waiting':row.status,
    progressText:waiting?'Waiting for this Mac':row.progress_text,createdAt:row.created_at,updatedAt:row.updated_at,
    createdBy:row.created_by,ownerDeviceId:row.owner_device_id,ownerDeviceName:row.owner_device_name,
    version:row.version,leaseExpiresAt:row.lease_expires_at,outputImageId:row.output_image_id,errorCode:row.error_code};
}
async function get(env:Env,projectId:string,jobId:string) {
  const row=await env.DB.prepare(`${SELECT_JOB} WHERE j.project_id=? AND j.id=?`).bind(Date.now(),projectId,jobId).first<JobRow>();
  assert(row,404,'job_not_found','Generation job not found.');return row;
}
async function receipt(env:Env,projectId:string,jobId:string,operationId:string) {
  return await env.DB.prepare('SELECT request_hash,actor_session_id,resulting_version FROM generation_job_operations WHERE project_id=? AND job_id=? AND operation_id=?')
    .bind(projectId,jobId,operationId).first<Receipt>();
}
function checkReceipt(value:Receipt,hash:string,identity:Identity) {
  assert(value.request_hash===hash&&value.actor_session_id===identity.sessionId,409,'operation_conflict','This operation ID was already used for a different request or device.');
}
export async function generationRoutes(request:Request,env:Env,identity:Identity):Promise<Response|null> {
  const url=new URL(request.url),match=/^\/v1\/projects\/([^/]+)\/generation-jobs(?:\/([^/]+)(?:\/(claim))?)?$/.exec(url.pathname);
  if(!match)return null;
  const projectId=id(match[1]),jobId=match[2]?uuid(match[2],'jobId'):null,claim=match[3]==='claim';
  const access=await projectAccess(env,projectId,identity.user.id);
  if(request.method==='GET'&&!claim) {
    if(jobId)return json({job:view(await get(env,projectId,jobId))});
    const limit=int(Number(url.searchParams.get('limit')??100),'limit',1,100),cursor=url.searchParams.get('cursor');
    let beforeTime=Number.MAX_SAFE_INTEGER,beforeId='~';
    if(cursor){const parts=/^(\d+):([0-9a-f-]{36})$/i.exec(cursor);assert(parts,400,'invalid_cursor','Invalid generation jobs cursor.');beforeTime=int(Number(parts[1]),'cursor');beforeId=uuid(parts[2],'cursor');}
    const result=await env.DB.prepare(`${SELECT_JOB} WHERE j.project_id=? AND (j.created_at<? OR (j.created_at=? AND j.id<?)) ORDER BY j.created_at DESC,j.id DESC LIMIT ?`)
      .bind(Date.now(),projectId,beforeTime,beforeTime,beforeId,limit+1).all<JobRow>();
    const rows=result.results.slice(0,limit),last=rows.at(-1);
    return json({jobs:rows.map(row=>view(row)),nextCursor:result.results.length>limit&&last?`${last.created_at}:${last.id}`:null});
  }
  assert(access.canWrite,403,'not_allowed','This project is read-only.');
  assert((!jobId&&request.method==='POST')||(jobId&&((claim&&request.method==='POST')||(!claim&&request.method==='PATCH'))),405,'method_not_allowed','Use GET, POST, PATCH or POST claim for generation jobs.');
  const input=await body(request,4096);
  if(!jobId) {
    fields(input,['id','targetItemId','sourceRevision']);
    const newId=uuid(input.id,'id'),targetId=id(input.targetItemId,'targetItemId'),revision=int(input.sourceRevision,'sourceRevision'),now=Date.now();
    const result=await env.DB.prepare(`INSERT INTO generation_jobs(project_id,id,target_item_id,source_revision,created_by,owner_device_id,owner_device_name,status,progress_text,lease_expires_at,created_at,updated_at)
      SELECT ?,?,?,?,?,?,s.device_name,'queued','Queued on this Mac',?,?,? FROM sessions s WHERE s.id=? AND ${WRITE_ACCESS}
      ON CONFLICT(project_id,id) DO NOTHING RETURNING id`)
      .bind(projectId,newId,targetId,revision,identity.user.id,identity.sessionId,now+LEASE_MS,now,now,identity.sessionId,...accessArgs(identity,projectId,now)).first();
    if(!result) {
      // A duplicate create never starts or resets a job, even after it completed.
      // Recheck current rights before revealing a receipt after a slow request.
      const current=await projectAccess(env,projectId,identity.user.id);
      assert(current.canWrite,409,'access_changed','Project access changed. Refresh and retry.');
      const session=await env.DB.prepare('SELECT id FROM sessions WHERE id=? AND user_id=? AND revoked_at IS NULL AND expires_at>?').bind(identity.sessionId,identity.user.id,Date.now()).first();
      assert(session,401,'session_expired','Your Scriv session has expired.');
      const existing=await get(env,projectId,newId);
      assert(existing.created_by===identity.user.id&&existing.target_item_id===targetId&&existing.source_revision===revision,409,'job_conflict','This job ID was already used for different work.');
      return json({job:view(existing),replayed:true});
    }
    return json({job:view(await get(env,projectId,newId))},201);
  }
  fields(input,claim?['operationId','expectedVersion','recover']:['operationId','expectedVersion','status','progressText','outputImageId','errorCode']);
  const operationId=uuid(input.operationId,'operationId'),expected=int(input.expectedVersion,'expectedVersion',1);
  const hash=await sha256(stableJSON({action:claim?'claim':'update',...input}));
  const existing=await get(env,projectId,jobId);
  assert(existing.created_by===identity.user.id,403,'not_job_owner','Only the person who created this job can control its local generation.');
  const prior=await receipt(env,projectId,jobId,operationId);
  if(prior) {
    checkReceipt(prior,hash,identity);
    // Replaying an old claim returns CURRENT state, never a stale execution grant.
    const session=await env.DB.prepare('SELECT id FROM sessions WHERE id=? AND user_id=? AND revoked_at IS NULL AND expires_at>?').bind(identity.sessionId,identity.user.id,Date.now()).first();
    assert(session,401,'session_expired','Your Scriv session has expired.');
    const current=await projectAccess(env,projectId,identity.user.id);assert(current.canWrite,409,'access_changed','Project access changed.');
    return json({job:view(await get(env,projectId,jobId)),replayed:true});
  }
  let status:Status,progress:string,output:string|null=null,error:string|null=null;
  const now=Date.now();
  if(claim) {
    assert(input.recover===undefined||typeof input.recover==='boolean',400,'invalid_field','recover must be a boolean.');
    status='running';progress='Starting on this Mac';
  } else {
    assert(['running','waiting','completed','cancelled','failed'].includes(String(input.status)),400,'invalid_field','Invalid generation job status.');
    status=input.status as Exclude<Status,'queued'>;
    progress=input.progressText===undefined?({running:'Generating on this Mac',waiting:'Waiting for this Mac',completed:'Completed',cancelled:'Cancelled',failed:'Generation failed'}[status]):str(input.progressText,'progressText',160);
    assert(!/[\u0000-\u001f\u007f]/.test(progress),400,'invalid_field','Progress must be a single short line.');
    if(input.outputImageId!==undefined&&input.outputImageId!==null)output=id(input.outputImageId,'outputImageId');
    assert(status==='completed'?!!output:output===null,400,'invalid_field','Only completed jobs have an output image ID.');
    if(input.errorCode!==undefined&&input.errorCode!==null){error=str(input.errorCode,'errorCode',48);assert(/^[a-z][a-z0-9_]*$/.test(error),400,'invalid_field','Use a short error code, not a provider response.');}
    assert(error===null||status==='failed'||status==='waiting'||status==='cancelled',400,'invalid_field','Only failed, waiting or cancelled jobs have an error code.');
  }
  // A live running claim cannot be stolen, even by another Mac of the same user.
  // Explicit recovery fences the previous runner; completed results are immutable.
  const gate=claim?`status!='completed' AND (
    (status='queued' AND owner_device_id=?) OR
    (?=1 AND (status IN ('waiting','failed','cancelled') OR lease_expires_at<=? OR NOT EXISTS(
      SELECT 1 FROM sessions previous_owner WHERE previous_owner.id=owner_device_id AND previous_owner.user_id=created_by
      AND previous_owner.revoked_at IS NULL AND previous_owner.expires_at>?))))`:
    `status IN ('queued','running','waiting') AND ${status==='cancelled'?'1=1':`status='running' AND owner_device_id=? AND lease_expires_at>?`}`;
  const gateArgs=claim?[identity.sessionId,input.recover===true?1:0,now,now]:status==='cancelled'?[]:[identity.sessionId,now];
  const update=env.DB.prepare(`UPDATE generation_jobs SET status=?,progress_text=?,owner_device_id=?,
    owner_device_name=(SELECT device_name FROM sessions WHERE id=?),lease_expires_at=?,output_image_id=?,error_code=?,
    updated_at=?,version=version+1,last_operation_id=?
    WHERE project_id=? AND id=? AND created_by=? AND version=? AND ${gate} AND ${WRITE_ACCESS}
    AND NOT EXISTS(SELECT 1 FROM generation_job_operations o WHERE o.project_id=? AND o.job_id=? AND o.operation_id=?)`)
    .bind(status,progress,identity.sessionId,identity.sessionId,status==='running'?now+LEASE_MS:0,output,error,now,operationId,
      projectId,jobId,identity.user.id,expected,...gateArgs,...accessArgs(identity,projectId,now),projectId,jobId,operationId);
  // D1 batch is transactional: never publish a claim without its idempotency receipt.
  await env.DB.batch([update,env.DB.prepare(`INSERT INTO generation_job_operations(project_id,job_id,operation_id,request_hash,actor_session_id,resulting_version,created_at)
    SELECT project_id,id,?,?,?,?,? FROM generation_jobs WHERE project_id=? AND id=? AND version=? AND last_operation_id=?
    ON CONFLICT(project_id,job_id,operation_id) DO NOTHING`)
    .bind(operationId,hash,identity.sessionId,expected+1,now,projectId,jobId,expected+1,operationId)]);
  const committed=await receipt(env,projectId,jobId,operationId);
  assert(committed,409,'job_conflict','Job ownership, version or project access changed. Refresh before retrying.');
  checkReceipt(committed,hash,identity);
  return json({job:view(await get(env,projectId,jobId))});
}
