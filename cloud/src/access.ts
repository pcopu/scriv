import type { Env, Identity, ProjectAccess, ProjectRow, Role, TeamRow } from './types';
import { assert, sha256 } from './http';
export async function authenticate(request: Request, env: Env): Promise<Identity> {
  const header = request.headers.get('authorization') ?? '';
  assert(header.startsWith('Bearer ') && header.length < 500,401,'sign_in_required','Sign in to Scriv to continue.');
  const tokenHash = await sha256(header.slice(7));
  const row = await env.DB.prepare(`SELECT s.id session_id,s.expires_at,u.id,u.name,u.email,u.avatar_url FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>?`)
    .bind(tokenHash,Date.now()).first<{session_id:string;expires_at:number;id:string;name:string;email:string|null;avatar_url:string|null}>();
  assert(row,401,'session_expired','Your Scriv session has expired. Sign in again.');
  return {user:{id:row.id,name:row.name,email:row.email,avatarUrl:row.avatar_url},sessionId:row.session_id,tokenHash,expiresAt:row.expires_at};
}
export function premium(team: TeamRow | null): boolean {
  return !!team && ['active','trialing'].includes(team.subscription_status) && (team.paid_until ?? 0) > Date.now();
}
export async function getTeam(env: Env, teamId: string): Promise<TeamRow> {
  const team = await env.DB.prepare('SELECT * FROM teams WHERE id=?').bind(teamId).first<TeamRow>();
  assert(team,404,'not_found','Team not found.'); return team;
}
export async function teamRole(env: Env, teamId: string, userId: string): Promise<Role | null> {
  return (await env.DB.prepare('SELECT role FROM team_members WHERE team_id=? AND user_id=?').bind(teamId,userId).first<{role:Role}>())?.role ?? null;
}
export async function requireTeam(env: Env, teamId: string, userId: string, roles?: Role[]): Promise<{team:TeamRow;role:Role}> {
  const role = await teamRole(env,teamId,userId);
  assert(role,404,'not_found','Team not found.');
  assert(!roles || roles.includes(role),403,'not_allowed','You do not have permission to manage this team.');
  return {team:await getTeam(env,teamId),role};
}
export function teamView(team: TeamRow, role?: Role) {
  return {id:team.id,name:team.name,ownerId:team.owner_id,role,plan:premium(team)?'team':'free',status:team.subscription_status,currentPeriodEnd:team.current_period_end,storageUsed:team.storage_used,createdAt:team.created_at,...(role==='owner'?{billingCustomer:!!team.stripe_customer_id}:{})};
}
export function projectView(project: ProjectRow, access?: Pick<ProjectAccess,'role'|'premium'|'canWrite'>) {
  return {id:project.id,title:project.title,ownerId:project.owner_id,teamId:project.team_id,createdAt:project.created_at,updatedAt:project.updated_at,archivedAt:project.archived_at,...(access ?? {})};
}
export async function projectAccess(env: Env, projectId: string, userId: string): Promise<ProjectAccess> {
  const project = await env.DB.prepare('SELECT * FROM projects WHERE id=? AND archived_at IS NULL').bind(projectId).first<ProjectRow>();
  assert(project,404,'not_found','Project not found.');
  const team = project.team_id ? await getTeam(env,project.team_id) : null;
  const role = project.team_id ? await teamRole(env,project.team_id,userId) : null;
  // Team ownership is authoritative; a historical catalog owner must not bypass membership.
  const owner = team ? userId === team.owner_id : userId === project.owner_id;
  assert(owner || role,404,'not_found','Project not found.');
  const paid = premium(team);
  // A lapsed team's members retain read/export access for 30 days. Ownership is never lost.
  const graceRead = team && Date.now() < (team.canceled_at ?? team.paid_until ?? 0) + 30 * 86400000;
  assert(owner || paid || graceRead,402,'team_subscription_required','This team subscription is inactive. Ask the owner to reactivate it.');
  return {project,role:owner?'owner':role!,premium:paid,canWrite:owner || (paid && role !== 'viewer'),canManage:owner || (paid && role === 'admin'),team};
}
