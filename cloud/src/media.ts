import type { Env, Identity } from './types';
import { projectAccess } from './access';
import { APIError, assert, bytes, id, json, rateLimit, sha256 } from './http';

interface AssetRow {project_id:string;sha256:string;team_id:string;asset_id:string|null;object_key:string;content_type:string;bytes:number;state:'uploading'|'ready'|'deleting';uploaded_by:string;created_at:number}
function mediaType(data:Uint8Array):string|null{
  if(data.length>=8&&[137,80,78,71,13,10,26,10].every((b,i)=>data[i]===b))return'image/png';
  if(data.length>=3&&data[0]===255&&data[1]===216&&data[2]===255)return'image/jpeg';
  if(data.length>=12&&new TextDecoder().decode(data.subarray(0,4))==='RIFF'&&new TextDecoder().decode(data.subarray(8,12))==='WEBP')return'image/webp';
  return null;
}
export async function mediaRoutes(request:Request,env:Env,identity:Identity):Promise<Response|null>{
  const path=new URL(request.url).pathname;
  const match=/^\/v1\/projects\/([^/]+)\/assets\/([a-f0-9]{64})$/.exec(path);if(!match)return null;
  const projectId=id(match[1]),hash=match[2]!,access=await projectAccess(env,projectId,identity.user.id);
  const row=await env.DB.prepare('SELECT * FROM assets WHERE project_id=? AND sha256=?').bind(projectId,hash).first<AssetRow>();
  if(request.method==='GET'||request.method==='HEAD'){
    assert(row?.state==='ready',404,'asset_unavailable','This image has no hosted copy. Request it from an online peer.');
    const object=request.method==='HEAD'?await env.MEDIA.head(row.object_key):await env.MEDIA.get(row.object_key);
    assert(object,404,'asset_unavailable','The hosted copy is unavailable. Request it from another device.');
    const headers=new Headers({'content-type':row.content_type,'content-length':String(row.bytes),'cache-control':'private, no-store','x-content-type-options':'nosniff','etag':`"${hash}"`,'x-scriv-sha256':hash});
    return new Response(request.method==='HEAD'?null:(object as R2ObjectBody).body,{headers});
  }
  if(request.method==='DELETE'){
    assert(access.canManage,403,'not_allowed','Only an owner or administrator can delete hosted images.');
    if(!row)return json({ok:true});
    assert(row.state!=='uploading',409,'upload_in_progress','Wait for the current image upload to finish before deleting it.');
    await env.DB.prepare("UPDATE assets SET state='deleting' WHERE project_id=? AND sha256=?").bind(projectId,hash).run();
    await env.MEDIA.delete(row.object_key);
    await env.DB.prepare("DELETE FROM assets WHERE project_id=? AND sha256=? AND state='deleting'").bind(projectId,hash).run();
    return json({ok:true});
  }
  assert(request.method==='PUT',405,'method_not_allowed','Use GET, PUT or DELETE for image media.');
  assert(access.premium&&access.team&&access.canWrite,402,'team_subscription_required','Hosted image storage requires an active Team subscription.');
  await rateLimit(env,`upload:${identity.user.id}`,120,3600000);
  const limit=Math.min(26214400,Number(env.ASSET_MAX_BYTES)||26214400);
  const content=await bytes(request,limit);assert(content.length>0,400,'empty_media','The image is empty.');
  const type=mediaType(content);assert(type&&type===request.headers.get('content-type')?.split(';')[0],415,'invalid_media','The bytes must match a PNG, JPEG or WebP Content-Type.');
  assert(await sha256(content)===hash,422,'hash_mismatch','Image SHA-256 does not match its content-addressed URL.');
  if(row){assert(row.state==='ready',409,'upload_in_progress','This image is already being transferred. Retry shortly.');assert(row.bytes===content.length&&row.content_type===type,409,'asset_conflict','The stored image metadata does not match.');return json({sha256:hash,bytes:row.bytes,hosted:true});}
  const assetId=request.headers.get('x-scriv-asset-id');if(assetId)id(assetId,'assetId');
  const key=`projects/${projectId}/${hash}`,now=Date.now();
  let reserved:unknown;
  try{reserved=await env.DB.prepare("INSERT INTO assets(project_id,sha256,team_id,asset_id,object_key,content_type,bytes,state,uploaded_by,created_at) VALUES(?,?,?,?,?,?,?,'uploading',?,?) ON CONFLICT(project_id,sha256) DO NOTHING RETURNING sha256")
    .bind(projectId,hash,access.team.id,assetId,key,type,content.length,identity.user.id,now).first();}
  catch(error){if(String(error).includes('team_storage_quota'))throw new APIError(413,'storage_quota','This team has reached its hosted image storage quota. Remove hosted replicas or raise the quota.');throw error;}
  assert(reserved,409,'upload_in_progress','Another device is uploading this image. Retry shortly.');
  try{
    await env.MEDIA.put(key,content,{httpMetadata:{contentType:type},customMetadata:{sha256:hash,projectId,teamId:access.team.id}});
    await env.DB.prepare("UPDATE assets SET state='ready' WHERE project_id=? AND sha256=? AND state='uploading' AND created_at=?").bind(projectId,hash,now).run();
  }catch(error){
    // Leave a recoverable reservation when R2 or D1 acknowledgement is uncertain.
    // Scheduled reconciliation validates R2 metadata before finalizing or reclaiming quota.
    throw new APIError(503,'upload_pending','The image upload could not be confirmed. Retry later; your local copy is unchanged.');
  }
  return json({sha256:hash,bytes:content.length,hosted:true},201);
}
export async function iceServers(request:Request,env:Env,identity:Identity,projectId:string):Promise<Response>{
  await projectAccess(env,projectId,identity.user.id);
  await rateLimit(env,`turn:${identity.sessionId}`,20,3600000);
  const fallback=[{urls:['stun:stun.cloudflare.com:3478']}];
  if(!env.TURN_KEY_ID||!env.TURN_API_TOKEN)return json({iceServers:fallback,relayAvailable:false,expiresAt:Date.now()+3600000});
  const response=await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`,{method:'POST',headers:{authorization:`Bearer ${env.TURN_API_TOKEN}`,'content-type':'application/json'},body:JSON.stringify({ttl:3600}),signal:AbortSignal.timeout(10000)});
  assert(response.ok,502,'turn_unavailable','The peer relay could not be configured. Retry or use the hosted image copy.');
  const data=await response.json<{iceServers:unknown}>();assert(Array.isArray(data.iceServers),502,'turn_unavailable','Peer relay returned invalid credentials.');
  return json({iceServers:data.iceServers,relayAvailable:true,expiresAt:Date.now()+3600000});
}
export async function projectDevices(env:Env,identity:Identity,projectId:string):Promise<Response>{
  const access=await projectAccess(env,projectId,identity.user.id);
  const rows=await env.DB.prepare(`SELECT s.id,s.device_name deviceName,s.user_id userId,u.name,s.created_at createdAt,s.expires_at expiresAt FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.revoked_at IS NULL AND s.expires_at>? AND (s.user_id=? OR (?=1 AND EXISTS(SELECT 1 FROM team_members m WHERE m.team_id=? AND m.user_id=s.user_id))) ORDER BY s.created_at DESC LIMIT 1000`)
    .bind(Date.now(),identity.user.id,access.premium?1:0,access.project.team_id).all();
  return json({currentDeviceId:identity.sessionId,devices:rows.results,onlineStatus:'unknown'});
}
export async function reconcileMedia(env:Env):Promise<void>{
  const rows=await env.DB.prepare("SELECT * FROM assets WHERE state!='ready' AND created_at<? ORDER BY created_at LIMIT 100").bind(Date.now()-3600000).all<AssetRow>();
  for(const row of rows.results){
    try{
      const object=await env.MEDIA.head(row.object_key);
      if(row.state==='uploading'&&object?.size===row.bytes&&object.customMetadata?.sha256===row.sha256){await env.DB.prepare("UPDATE assets SET state='ready' WHERE project_id=? AND sha256=? AND state='uploading'").bind(row.project_id,row.sha256).run();}
      else{if(object)await env.MEDIA.delete(row.object_key);await env.DB.prepare("DELETE FROM assets WHERE project_id=? AND sha256=? AND state!='ready'").bind(row.project_id,row.sha256).run();}
    }catch{console.error('Media reconciliation deferred');}
  }
}
