export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  PROJECTS: DurableObjectNamespace;
  BILLING: DurableObjectNamespace;
  ENVIRONMENT: string;
  PUBLIC_URL: string;
  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  STRIPE_SECRET_KEY?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  STRIPE_TEAM_PRICE_ID?: string;
  TEAM_PRICE_CENTS: string;
  ASSET_MAX_BYTES: string;
  TEAM_STORAGE_BYTES: string;
  SESSION_DAYS: string;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
}
export interface User { id: string; name: string; email: string | null; avatarUrl: string | null }
export interface Identity { user: User; sessionId: string; tokenHash: string; expiresAt: number }
export type Role = 'owner' | 'admin' | 'member' | 'viewer';
export interface TeamRow {
  id: string; name: string; owner_id: string; created_at: number;
  stripe_customer_id: string | null; subscription_id: string | null;
  subscription_status: string; current_period_end: number | null; canceled_at: number | null;
  paid_until: number | null; billing_checked_at: number | null; storage_used: number;
}
export interface ProjectRow { id: string; title: string; owner_id: string; team_id: string | null; created_at: number; updated_at: number; archived_at: number | null }
export interface ProjectAccess { project: ProjectRow; role: Role; premium: boolean; canWrite: boolean; canManage: boolean; team: TeamRow | null }
export type ItemKind = 'scene' | 'entry' | 'character' | 'image' | 'cue';
export interface Item { id: string; kind: ItemKind; version: number; data: Record<string, unknown>; deleted: boolean }
export interface Lease { itemId: string; sessionId: string; token: string; fence: number; expiresAt: number; epoch: number; userId: string; name: string }
export interface Operation { op: 'put' | 'delete'; id: string; kind?: ItemKind; data?: Record<string, unknown>; expectedVersion: number; lease?: {token: string; fence: number} }
export interface Command { commandId: string; sessionId: string; epoch: number; expectedTimingVersion?: number; label: string; operations: Operation[] }
export interface Change { id: string; before: Item | null; after: Item }
export interface ProjectEvent { seq: number; epoch: number; commandId: string; actorId: string; kind: string; at: number; changes: Change[]; data: Record<string, unknown> }
