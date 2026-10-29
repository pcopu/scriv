import type { Env } from './types';
export class APIError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: unknown) { super(message); }
}
export function assert(condition: unknown, status: number, code: string, message: string, details?: unknown): asserts condition {
  if (!condition) throw new APIError(status, code, message, details);
}
export function json(data: unknown, status = 200, headers?: HeadersInit): Response {
  const h = new Headers(headers);
  h.set('content-type', 'application/json; charset=utf-8');
  h.set('cache-control', 'no-store');
  h.set('x-content-type-options', 'nosniff');
  h.set('referrer-policy', 'no-referrer');
  return new Response(JSON.stringify(data), { status, headers: h });
}
export function failure(error: unknown): Response {
  if (error instanceof APIError) return json({ error: { code: error.code, message: error.message, ...(error.details === undefined ? {} : { details: error.details }) } }, error.status);
  // Do not put provider responses, session tokens, or request bodies in logs or errors.
  console.error('Scriv request failed', error instanceof Error ? error.name : 'UnknownError');
  return json({ error: { code: 'internal_error', message: 'The server could not complete this request. Please retry.' } }, 500);
}
export async function body<T = Record<string, unknown>>(request: Request, limit = 524288): Promise<T> {
  const data = await bytes(request, limit);
  try { return JSON.parse(new TextDecoder().decode(data)) as T; }
  catch { throw new APIError(400, 'invalid_json', 'Request body must be valid JSON.'); }
}
export async function bytes(request: Request, limit: number): Promise<Uint8Array> {
  const length = request.headers.get('content-length');
  assert(!length || (Number.isSafeInteger(Number(length)) && Number(length) <= limit), 413, 'body_too_large', 'Request exceeds the size limit.');
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = []; let total = 0;
  while (true) {
    const { value, done } = await reader.read(); if (done) break;
    total += value.byteLength;
    if (total > limit) { await reader.cancel(); throw new APIError(413, 'body_too_large', 'Request exceeds the size limit.'); }
    chunks.push(value);
  }
  const result = new Uint8Array(total); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
export function str(value: unknown, name: string, max = 200, min = 1): string {
  assert(typeof value === 'string' && value.length >= min && value.length <= max, 400, 'invalid_field', `${name} must be ${min}–${max} characters.`);
  return value;
}
export function id(value: unknown, name = 'id'): string {
  const result = str(value, name, 128);
  assert(/^[a-zA-Z0-9][a-zA-Z0-9._:-]*$/.test(result), 400, 'invalid_id', `${name} contains unsupported characters.`);
  return result;
}
export function int(value: unknown, name: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  assert(typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max, 400, 'invalid_field', `${name} must be an integer between ${min} and ${max}.`);
  return value;
}
export function record(value: unknown, name = 'data'): Record<string, unknown> {
  assert(value !== null && typeof value === 'object' && !Array.isArray(value), 400, 'invalid_field', `${name} must be an object.`);
  return value as Record<string, unknown>;
}
export const uuid = () => crypto.randomUUID();
export function base64url(value: Uint8Array): string { return btoa(String.fromCharCode(...value)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, ''); }
export function randomToken(size = 32): string { return base64url(crypto.getRandomValues(new Uint8Array(size))); }
export async function sha256(value: string | Uint8Array): Promise<string> {
  const buffer = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', buffer as BufferSource))].map(b => b.toString(16).padStart(2, '0')).join('');
}
export async function challenge(verifier: string): Promise<string> { return base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))); }
export function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.entries(value).filter(([,v]) => v !== undefined).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => `${JSON.stringify(k)}:${stableJSON(v)}`).join(',')}}`;
  return JSON.stringify(value);
}
export async function rateLimit(env: Env, key: string, limit: number, windowMs = 60000): Promise<void> {
  const now = Date.now(); const bucket = Math.floor(now / windowMs);
  const row = await env.DB.prepare('INSERT INTO security_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count')
    .bind(`${key}:${bucket}`, (bucket + 2) * windowMs).first<{count: number}>();
  assert(row && row.count <= limit, 429, 'rate_limited', 'Too many requests. Please wait and retry.');
}
export function publicBase(env: Env): string {
  const url = new URL(env.PUBLIC_URL);
  assert(url.protocol === 'https:' || (env.ENVIRONMENT !== 'production' && ['localhost','127.0.0.1'].includes(url.hostname)), 503, 'configuration', 'Service URL is not configured.');
  assert(!url.hostname.includes('YOUR_'),503,'configuration','Service URL is not configured.');
  return url.origin;
}
export function escapeHTML(value: string): string { return value.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!)); }
