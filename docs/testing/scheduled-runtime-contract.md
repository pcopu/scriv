# Local scheduled-event adapter reference

The maintenance CLI journey uses Miniflare 5.20261023.2-beta (MIT) from the
existing locked development dependency, not a production Scriv endpoint.
The fixture enables unsafeTriggerHandlers only on its owned 127.0.0.1 server.
The local endpoint is /cdn-cgi/local/scheduled?format=json. No time or cron
override is supplied. Worker source and production deployment settings are
unchanged. The response reports the platform event outcome; separate bounded
state assertions establish the expected maintenance results.

This is an excerpted dependency contract for reproducible review, not a vendored
runtime or execution substitute. The existing installed package supplies the
actual implementation. Recheck these excerpts and file identities if that
dependency changes.

Exact installed UTF-8 file SHA-256 values:

- dist/src/workers/core/entry.worker.js: b7c40f17aadb255c3d81892fea82977d10e1ebcab32551f8f7c3867d07f5b756
- dist/src/index.js: 3246120a9772a73e081a99176b4879ab258244ff6b828167add92417a442303d

Upstream project: https://github.com/cloudflare/workers-sdk/tree/main/packages/miniflare

## Local scheduled-event dispatcher

From dist/src/workers/core/entry.worker.js, lines 4187–4200. Exact excerpt SHA-256: 9aab0c1e0c5325079a02ac91df57a47f2fb533702bf236d5c4dafdd1d99498fe.

```javascript
// src/workers/core/scheduled.ts
function dispatchScheduled(service, options) {
  return service.scheduled(options);
}
async function handleScheduled(params, service) {
  let time = params.get("time"), scheduledTime = time ? new Date(parseInt(time)) : void 0, cron = params.get("cron") ?? void 0, format = params.get("format"), result = await dispatchScheduled(service, {
    scheduledTime,
    cron
  });
  return format === "json" ? Response.json(result, {
    status: result.outcome === "ok" ? 200 : 500
  }) : new Response(result.outcome, {
    status: result.outcome === "ok" ? 200 : 500
  });
```

## Reserved route guard

From dist/src/workers/core/entry.worker.js, lines 5342–5344. Exact excerpt SHA-256: abe0752fb70f667354cf427a040bfe2cc6670ea65ff0b425cfa7a507a2a6f415.

```javascript
      if (env[CoreBindings.TRIGGER_HANDLERS]) {
        if (url.pathname === CorePaths.SCHEDULED)
          return await handleScheduled(url.searchParams, service);
```

## Configuration binding

From dist/src/index.js, lines 123663–123667. Exact excerpt SHA-256: d3eb361eb5b368c6e26dc4075a0cf4788c0b102f7d814ea4c6a38f67eb4cfb5b.

```javascript
    {
      name: CoreBindings.TRIGGER_HANDLERS,
      json: JSON.stringify(!!sharedOptions.unsafeTriggerHandlers)
    },
    {
```

