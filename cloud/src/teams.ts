import { refreshProjectAccess, refreshTeamAccess } from './notifications';
import type { Env, Identity, ProjectRow, Role, TeamRow } from './types';
import { getTeam, premium, projectAccess, projectView, requireTeam, teamView } from './access';
import { APIError, assert, body, escapeHTML, id, int, json, publicBase, randomToken, rateLimit, sha256, str, uuid } from './http';

export async function listTeams(env: Env, userId: string) {
  const rows = await env.DB.prepare('SELECT t.*,m.role FROM teams t JOIN team_members m ON m.team_id=t.id WHERE m.user_id=? ORDER BY t.created_at DESC').bind(userId).all<TeamRow&{role:Role}>();
  return rows.results.map(t=>teamView(t,t.role));
}
export async function listProjects(env: Env, userId: string) {
  const rows = await env.DB.prepare(`SELECT DISTINCT p.* FROM projects p LEFT JOIN team_members m ON m.team_id=p.team_id AND m.user_id=? WHERE p.archived_at IS NULL AND (p.owner_id=? OR m.user_id=?) ORDER BY p.updated_at DESC`).bind(userId,userId,userId).all<ProjectRow>();
  const result: ReturnType<typeof projectView>[] = [];
  for (const p of rows.results) {
    try { const a=await projectAccess(env,p.id,userId); result.push(projectView(p,{role:a.role,premium:a.premium,canWrite:a.canWrite})); } catch(error) {
      // Hide revoked/expired projects, not database failures or programmer errors.
      if(!(error instanceof APIError)||![402,403,404].includes(error.status))throw error;
    }
  }
  return result;
}
export async function teamRoutes(request: Request, env: Env, identity: Identity): Promise<Response | null> {
  const path=new URL(request.url).pathname; const method=request.method; const userId=identity.user.id;
  // Requests can wait on their body or external I/O after initial authorization.
  // Every D1 mutation rechecks the device session in the same SQL statement.
  const liveSession=`EXISTS(SELECT 1 FROM sessions actor_session WHERE actor_session.id=? AND actor_session.user_id=? AND actor_session.revoked_at IS NULL AND actor_session.expires_at>?)`;
  const sessionArgs=()=>[identity.sessionId,userId,Date.now()];
  const manager=`EXISTS(SELECT 1 FROM team_members actor WHERE actor.team_id=? AND actor.user_id=? AND actor.role IN ('owner','admin'))`;
  const changedMessage='Access changed while this request was in progress. Refresh and retry.';
  if (path==='/v1/me' && method==='GET') return json({user:identity.user,sessionId:identity.sessionId,teams:await listTeams(env,userId),projects:await listProjects(env,userId)});
  if (path==='/v1/teams') {
    if(method==='GET') return json({teams:await listTeams(env,userId)});
    if(method==='POST') {
      await rateLimit(env,`team-create:${userId}`,20,86400000);
      const input=await body(request,4096); const name=str(input.name,'name',100).trim(); assert(name,400,'invalid_name','Enter a team name.');
      const teamId=uuid(); const now=Date.now();
      const created=await env.DB.batch([
        env.DB.prepare(`INSERT INTO teams(id,name,owner_id,created_at,storage_limit) SELECT ?,?,?,?,? WHERE ${liveSession}`).bind(teamId,name,userId,now,Number(env.TEAM_STORAGE_BYTES)||10737418240,...sessionArgs()),
        env.DB.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) SELECT id,owner_id,'owner',? FROM teams WHERE id=?").bind(now,teamId)
      ]);
      assert(created[0]?.meta.changes,401,'session_expired','Your Scriv session has expired. Sign in again.');
      return json({team:teamView(await getTeam(env,teamId),'owner')},201);
    }
  }
  const teamMatch=/^\/v1\/teams\/([^/]+)$/.exec(path);
  if(teamMatch) {
    const teamId=id(teamMatch[1]); const {team,role}=await requireTeam(env,teamId,userId);
    if(method==='GET') {
      const members=await env.DB.prepare('SELECT u.id,u.name,u.email,u.avatar_url avatarUrl,m.role,m.joined_at joinedAt FROM team_members m JOIN users u ON u.id=m.user_id WHERE m.team_id=? ORDER BY m.joined_at').bind(teamId).all();
      const links=['owner','admin'].includes(role)?await env.DB.prepare('SELECT id,role,created_at createdAt,expires_at expiresAt,revoked_at revokedAt FROM join_links WHERE team_id=? ORDER BY created_at DESC').bind(teamId).all():{results:[]};
      return json({team:teamView(team,role),members:members.results,joinLinks:links.results});
    }
    if(method==='PATCH') {
      assert(['owner','admin'].includes(role),403,'not_allowed','Only team administrators can rename the team.');
      const input=await body(request,4096); const name=str(input.name,'name',100).trim();assert(name,400,'invalid_name','Enter a team name.');
      const changed=await env.DB.prepare(`UPDATE teams SET name=? WHERE id=? AND ${manager} AND ${liveSession} RETURNING id`).bind(name,teamId,teamId,userId,...sessionArgs()).first();
      assert(changed,409,'access_changed',changedMessage);
      return json({team:teamView(await getTeam(env,teamId),role)});
    }
  }
  const linksMatch=/^\/v1\/teams\/([^/]+)\/join-links(?:\/([^/]+))?$/.exec(path);
  if(linksMatch) {
    const teamId=id(linksMatch[1]); await requireTeam(env,teamId,userId,['owner','admin']);
    if(method==='POST'&&!linksMatch[2]) {
      await rateLimit(env,`joinlink:${teamId}`,30,3600000);
      const input=await body(request,4096); const role=input.role??'member';assert(['member','viewer'].includes(String(role)),400,'invalid_role','Join links can grant member or viewer access.');
      const days=int(input.expiresInDays??30,'expiresInDays',1,365); const token=randomToken(); const now=Date.now(); const linkId=uuid();const expiresAt=now+days*86400000;
      const created=await env.DB.prepare(`INSERT INTO join_links(id,team_id,token_hash,role,created_by,created_at,expires_at)
        SELECT ?,?,?,?,?,?,? WHERE ${manager} AND ${liveSession} RETURNING id`).bind(linkId,teamId,await sha256(token),role,userId,now,expiresAt,teamId,userId,...sessionArgs()).first();
      assert(created,409,'access_changed',changedMessage);
      return json({token,url:`${publicBase(env)}/join/${token}`,link:{id:linkId,role,createdAt:now,expiresAt}},201);
    }
    if(method==='DELETE'&&linksMatch[2]) {await env.DB.prepare(`UPDATE join_links SET revoked_at=? WHERE id=? AND team_id=? AND ${manager} AND ${liveSession}`).bind(Date.now(),id(linksMatch[2]),teamId,teamId,userId,...sessionArgs()).run();return json({ok:true});}
  }
  const joinMatch=/^\/v1\/join\/([A-Za-z0-9_-]{32,128})$/.exec(path);
  if(joinMatch&&method==='POST') {
    await rateLimit(env,`join:${userId}`,30,3600000);
    const link=await env.DB.prepare('SELECT * FROM join_links WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?').bind(await sha256(joinMatch[1]!),Date.now()).first<{id:string;team_id:string;role:'member'|'viewer'}>();
    assert(link,404,'invite_invalid','This invite has expired or been revoked.');
    const team=await getTeam(env,link.team_id);assert(premium(team),402,'team_subscription_required','The team owner needs an active Team subscription before others can join.');
    const now=Date.now();
    // The invite and entitlement checks must also be part of the insertion:
    // revoking a link while a join is awaiting D1 cannot admit a new member.
    await env.DB.prepare(`INSERT INTO team_members(team_id,user_id,role,joined_at)
      SELECT t.id,?,l.role,? FROM join_links l JOIN teams t ON t.id=l.team_id
      WHERE l.id=? AND l.revoked_at IS NULL AND l.expires_at>?
        AND t.subscription_status IN ('active','trialing') AND t.paid_until>? AND ${liveSession}
      ON CONFLICT(team_id,user_id) DO NOTHING`).bind(userId,now,link.id,now,now,...sessionArgs()).run();
    const valid=await env.DB.prepare('SELECT id FROM join_links WHERE id=? AND revoked_at IS NULL AND expires_at>?').bind(link.id,Date.now()).first();
    assert(valid,404,'invite_invalid','This invite has expired or been revoked.');
    const current=await getTeam(env,team.id);assert(premium(current),402,'team_subscription_required','The team owner needs an active Team subscription before others can join.');
    const {role}=await requireTeam(env,team.id,userId);return json({team:teamView(current,role)});
  }
  const memberMatch=/^\/v1\/teams\/([^/]+)\/members\/([^/]+)$/.exec(path);
  if(memberMatch) {
    const teamId=id(memberMatch[1]); const memberId=id(memberMatch[2]); const {role}=await requireTeam(env,teamId,userId);
    const target=await env.DB.prepare('SELECT role FROM team_members WHERE team_id=? AND user_id=?').bind(teamId,memberId).first<{role:Role}>();
    assert(target,404,'not_found','Team member not found.'); assert(target.role!=='owner',409,'owner_required','Team ownership must be transferred before the owner can leave.');
    assert(role==='owner'||(role==='admin'&&target.role!=='admin')||(memberId===userId&&method==='DELETE'),403,'not_allowed','You cannot change this membership.');
    if(method==='PATCH') {
      const input=await body(request,4096);assert(['admin','member','viewer'].includes(String(input.role)),400,'invalid_role','Choose admin, member, or viewer.');
      assert(input.role!=='admin'||role==='owner',403,'not_allowed','Only the owner can appoint an admin.');
      const changed=await env.DB.prepare(`UPDATE team_members SET role=? WHERE team_id=? AND user_id=? AND role<>'owner'
        AND EXISTS(SELECT 1 FROM team_members actor WHERE actor.team_id=? AND actor.user_id=?
          AND (actor.role='owner' OR (actor.role='admin' AND team_members.role<>'admin' AND ?<>'admin')))
        AND ${liveSession} RETURNING user_id`).bind(input.role,teamId,memberId,teamId,userId,input.role,...sessionArgs()).first();
      assert(changed,409,'membership_changed','Membership changed while this request was in progress. Refresh and retry.');
      await refreshTeamAccess(env,teamId,memberId);return json({ok:true});
    }
    if(method==='DELETE') {
      const changed=await env.DB.prepare(`DELETE FROM team_members WHERE team_id=? AND user_id=? AND role<>'owner'
        AND (user_id=? OR EXISTS(SELECT 1 FROM team_members actor WHERE actor.team_id=? AND actor.user_id=?
          AND (actor.role='owner' OR (actor.role='admin' AND team_members.role<>'admin')))) AND ${liveSession} RETURNING user_id`).bind(teamId,memberId,userId,teamId,userId,...sessionArgs()).first();
      assert(changed,409,'membership_changed','Membership changed while this request was in progress. Refresh and retry.');
      await refreshTeamAccess(env,teamId,memberId);return json({ok:true});
    }
  }
  if(path==='/v1/projects') {
    if(method==='GET') return json({projects:await listProjects(env,userId)});
    if(method==='POST') {
      await rateLimit(env,`project-create:${userId}`,100,86400000);
      const input=await body(request,4096); const title=str(input.title,'title',200).trim();assert(title,400,'invalid_title','Enter a project title.');
      const projectId=input.id?id(input.id):uuid(); const teamId=input.teamId?id(input.teamId,'teamId'):null; let ownerId=userId;
      if(teamId){const {team,role}=await requireTeam(env,teamId,userId);assert(premium(team),402,'team_subscription_required','A Team subscription is required for team projects.');assert(role!=='viewer',403,'not_allowed','Viewers cannot create projects.');ownerId=team.owner_id;}
      const existing=await env.DB.prepare('SELECT * FROM projects WHERE id=?').bind(projectId).first<ProjectRow>();
      if(existing){assert(existing.owner_id===ownerId&&existing.team_id===teamId&&existing.title===title,409,'project_exists','This project ID is already in use.');assert(existing.archived_at===null,409,'project_archived','This project was archived. Create a new project instead.');return json({project:projectView(existing)});}
      const now=Date.now();
      const created=teamId
        ?await env.DB.prepare(`INSERT INTO projects(id,title,owner_id,team_id,created_at,updated_at)
          SELECT ?,?,t.owner_id,t.id,?,? FROM teams t JOIN team_members actor ON actor.team_id=t.id
          WHERE t.id=? AND actor.user_id=? AND actor.role IN ('owner','admin','member')
          AND t.subscription_status IN ('active','trialing') AND t.paid_until>? AND ${liveSession} RETURNING id`).bind(projectId,title,now,now,teamId,userId,now,...sessionArgs()).first()
        :await env.DB.prepare(`INSERT INTO projects(id,title,owner_id,team_id,created_at,updated_at) SELECT ?,?,?,NULL,?,? WHERE ${liveSession} RETURNING id`).bind(projectId,title,userId,now,now,...sessionArgs()).first();
      assert(created,409,'access_changed',changedMessage);
      return json({project:projectView({id:projectId,title,owner_id:ownerId,team_id:teamId,created_at:now,updated_at:now,archived_at:null})},201);
    }
  }
  const projectMatch=/^\/v1\/projects\/([^/]+)$/.exec(path);
  if(projectMatch) {
    const projectId=id(projectMatch[1]);const access=await projectAccess(env,projectId,userId);
    if(method==='GET')return json({project:projectView(access.project,{role:access.role,premium:access.premium,canWrite:access.canWrite})});
    assert(access.canManage,403,'not_allowed','Only a project owner or team administrator can manage the project.');
    const projectManager=`((team_id IS NULL AND owner_id=?) OR EXISTS(SELECT 1 FROM teams t LEFT JOIN team_members actor ON actor.team_id=t.id AND actor.user_id=?
      WHERE t.id=projects.team_id AND (t.owner_id=? OR (actor.role='admin' AND t.subscription_status IN ('active','trialing') AND t.paid_until>?))))`;
    if(method==='PATCH'){
      const input=await body(request,4096);const title=str(input.title,'title',200).trim();assert(title,400,'invalid_title','Enter a project title.');
      const updatedAt=Date.now();const changed=await env.DB.prepare(`UPDATE projects SET title=?,updated_at=? WHERE id=? AND archived_at IS NULL AND ${projectManager} AND ${liveSession} RETURNING id`).bind(title,updatedAt,projectId,userId,userId,userId,updatedAt,...sessionArgs()).first();
      assert(changed,409,'access_changed',changedMessage);
      return json({project:projectView({...access.project,title,updated_at:updatedAt})});
    }
    if(method==='DELETE') {const now=Date.now();const changed=await env.DB.prepare(`UPDATE projects SET archived_at=?,updated_at=? WHERE id=? AND archived_at IS NULL AND ${projectManager} AND ${liveSession} RETURNING id`).bind(now,now,projectId,userId,userId,userId,now,...sessionArgs()).first();assert(changed,409,'access_changed',changedMessage);await refreshProjectAccess(env,projectId);return json({ok:true});}
  }
  return null;
}
export function joinPage(token: string): Response {
  assert(/^[A-Za-z0-9_-]{32,128}$/.test(token),404,'not_found','Invite not found.');
  const target=`scriv://join/${token}`;
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Join a Scriv team</title><style>body{font:17px system-ui;max-width:32rem;margin:12vh auto;padding:2rem;background:#f5f7fc;color:#17213b}a{display:inline-block;background:#1769ff;color:white;padding:.8rem 1.4rem;border-radius:12px;text-decoration:none}p{line-height:1.6}small{color:#5b677e;word-break:break-all}</style><h1>Make the story together.</h1><p>Open this invitation in Scriv for Mac. Sign in with your own Scriv account to join the team.</p><a href="${escapeHTML(target)}">Open Scriv</a><p><small>Already in Scriv? Choose Join team and paste this invitation link.</small></p></html>`,{headers:{'content-type':'text/html; charset=utf-8','content-security-policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",'referrer-policy':'no-referrer','cache-control':'no-store'}});
}
