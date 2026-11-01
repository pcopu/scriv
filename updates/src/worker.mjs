// A read-only distribution surface. Publishing is exclusively through the
// authenticated R2 S3 API; no HTTP route can create/replace a release.
const HASH = /^[a-f0-9]{64}$/;
const ARTIFACT = /^\/releases\/[1-9][0-9]{0,14}\/[a-f0-9]{64}\.zip$/;
const MAX_FEED = 256 * 1024;
const security = { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'" };
function response(body, status, extra = {}) { return new Response(body, { status, headers: { ...security, 'Cache-Control': 'no-store', ...extra } }); }
export function validChannel(channel) { return channel === 'stable' || /^acceptance-[a-z0-9][a-z0-9-]{0,47}$/.test(channel); }
export function channelForPath(path) {
  if (path === '/appcast.xml') return 'stable';
  const match = /^\/channels\/(acceptance-[a-z0-9][a-z0-9-]{0,47})\/appcast\.xml$/.exec(path);
  return match ? match[1] : null;
}
export function validPointer(value, channel = 'stable') {
  return validChannel(channel) && value && value.channel === channel && value.schema === 1 && Number.isSafeInteger(value.build) && value.build > 0 && value.build <= 999999999999999 && HASH.test(value.feedSHA256) && value.feedKey === `feeds/${value.feedSHA256}.xml`;
}
export async function sha256(bytes) { return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x => x.toString(16).padStart(2, '0')).join(''); }
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!['GET', 'HEAD'].includes(request.method)) return response(null, 405, { Allow: 'GET, HEAD' });
    if (url.search || url.pathname.includes('%')) return response('Not found', 404);
    if (url.pathname === '/health') return response(request.method === 'HEAD' ? null : JSON.stringify({ service: 'scriv-updates', status: 'ok' }), 200, { 'Content-Type': 'application/json' });
    try {
      const channel = channelForPath(url.pathname);
      if (channel) {
        const pointerObject = await env.RELEASES.get(`channels/${channel}.json`);
        if (!pointerObject || pointerObject.size > 2048) return response('No signed release has been published.', 503, { 'Retry-After': '3600' });
        const pointer = await pointerObject.json();
        if (!validPointer(pointer, channel)) return response('Release metadata unavailable.', 503);
        const feed = await env.RELEASES.get(pointer.feedKey);
        if (!feed || feed.size > MAX_FEED) return response('Release metadata unavailable.', 503);
        const bytes = await feed.arrayBuffer();
        if (await sha256(bytes) !== pointer.feedSHA256) return response('Release metadata unavailable.', 503);
        // Preserve exact signed bytes. No XML rewriting, proxy HTML or analytics.
        return response(request.method === 'HEAD' ? null : bytes, 200, { 'Content-Type': 'application/xml; charset=utf-8', 'Content-Length': String(bytes.byteLength), ETag: `"${pointer.feedSHA256}"` });
      }
      if (!ARTIFACT.test(url.pathname)) return response('Not found', 404);
      const key = url.pathname.slice(1);
      const object = request.method === 'HEAD' ? await env.RELEASES.head(key) : await env.RELEASES.get(key);
      if (!object) return response('Not found', 404);
      const digest = key.split('/').at(-1).slice(0, -4);
      if (object.customMetadata?.sha256 !== digest) return response('Release artifact unavailable.', 503);
      const headers = { 'Content-Type': 'application/zip', 'Content-Length': String(object.size), 'Cache-Control': 'public, max-age=31536000, immutable', ETag: `"${digest}"`, 'Content-Disposition': 'attachment; filename="Scriv.zip"' };
      if (request.headers.get('If-None-Match') === headers.ETag) { const { 'Content-Length': ignored, ...cached } = headers; return response(null, 304, cached); }
      // Streaming avoids buffering app archives in Worker memory.
      return response(request.method === 'HEAD' ? null : object.body, 200, headers);
    } catch {
      // Do not expose bucket keys, request headers, user info or provider errors.
      return response('Update service temporarily unavailable.', 503, { 'Retry-After': '60' });
    }
  }
};
