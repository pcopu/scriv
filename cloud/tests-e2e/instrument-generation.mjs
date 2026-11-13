/** Narrow TypeScript probes for four reviewed modules; original production bytes stay unchanged. */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import ts from '../node_modules/typescript/lib/typescript.js';

const sha = value => createHash('sha256').update(value).digest('hex');
const prefix = '__scriv_generation_coverage_';
export const measuredSources = ['cloud/src/access.ts', 'cloud/src/generation.ts', 'cloud/src/http.ts', 'cloud/src/index.ts'];
export const collectorPath = '/__scriv_test_coverage__/snapshot';
export const nonceBinding = 'SCRIV_COVERAGE_NONCE';
export const counterNotice = 'Selected original statement-entry anchor lines only; not whole-line completion, branch coverage, all source lines or whole-project coverage.';

export function instrumentGeneration(source, { runId, probeSHA256, sourcePath }) {
  assert(measuredSources.includes(sourcePath));
  assert.equal(typeof source, 'string'); assert(Buffer.byteLength(source) <= 1024 * 1024);
  assert(!source.includes(prefix) && !source.includes(collectorPath));
  assert.match(runId, /^[0-9a-f-]{36}$/); assert.match(probeSHA256, /^[0-9a-f]{64}$/);
  const parsed = ts.createSourceFile(sourcePath, source, ts.ScriptTarget.ESNext, true, ts.ScriptKind.TS);
  assert.equal(parsed.parseDiagnostics.length, 0, 'Instrument only parseable original TypeScript');
  const first = parsed.statements[0];
  assert(!(first && ts.isExpressionStatement(first) && ts.isStringLiteral(first.expression)), 'Do not move a module directive behind the probe header');
  const sites = [];
  const selected = node => ts.isVariableStatement(node) || ts.isExpressionStatement(node)
    || ts.isReturnStatement(node) || ts.isThrowStatement(node) || ts.isIfStatement(node);
  function walk(node) {
    assert(!ts.isLabeledStatement(node) && !ts.isModuleDeclaration(node) && !ts.isClassStaticBlockDeclaration(node) && !ts.isDecorator(node), 'Unsupported unreviewed source construct');
    if (ts.isSourceFile(node) || ts.isBlock(node) || ts.isCaseClause(node) || ts.isDefaultClause(node)) {
      for (const statement of node.statements) {
        // Never prefix a directive or an export/declaration modifier. Descend into
        // real function/method blocks, but never wrap a standalone control body.
        if (!selected(statement) || (ts.isExpressionStatement(statement) && ts.isStringLiteral(statement.expression))
          || statement.modifiers?.length) continue;
        const start = statement.getStart(parsed), end = statement.end;
        const position = parsed.getLineAndCharacterOfPosition(start);
        sites.push({ start, end, line: position.line + 1, column: position.character,
          kind: ts.SyntaxKind[statement.kind], statementSHA256: sha(source.slice(start, end)) });
      }
    }
    ts.forEachChild(node, walk);
  }
  walk(parsed); sites.sort((a, b) => a.start - b.start);
  assert(sites.length > 0 && sites.length <= 4096);
  assert.equal(new Set(sites.map(site => site.start)).size, sites.length);
  const sourceSHA256 = sha(source), siteManifest = { version: 1, source: sourcePath, sourceSHA256, sites, notice: counterNotice };
  const siteManifestBytes = JSON.stringify(siteManifest, null, 2) + '\n', siteManifestSHA256 = sha(siteManifestBytes);
  let body = '', cursor = 0; const insertions = [];
  for (const [index, site] of sites.entries()) {
    body += source.slice(cursor, site.start);
    const text = `\n${prefix}hit(${index});\n`;
    insertions.push({ originalOffset: site.start, generatedOffset: body.length, text });
    body += text; cursor = site.start;
  }
  body += source.slice(cursor);
  let restored = body;
  for (const insertion of insertions.slice().reverse()) {
    assert.equal(restored.slice(insertion.generatedOffset, insertion.generatedOffset + insertion.text.length), insertion.text);
    restored = restored.slice(0, insertion.generatedOffset) + restored.slice(insertion.generatedOffset + insertion.text.length);
  }
  assert.equal(restored, source, 'Removing only recorded probe insertions exactly recovers original source');
  const header = `const ${prefix}counts = [${sites.map(() => '0').join(',')}];
let ${prefix}invalid = false, ${prefix}generation = null, ${prefix}sequence = 0;
function ${prefix}hit(index) {
  const value = ${prefix}counts[index];
  if (!Number.isSafeInteger(value) || value >= Number.MAX_SAFE_INTEGER) { ${prefix}invalid = true; return; }
  ${prefix}counts[index] = value + 1;
}
`;
  const footer = `\nexport function ${prefix}snapshot() {
  if (${prefix}generation === null) ${prefix}generation = crypto.randomUUID();
  return { version: 1, sourcePath: ${JSON.stringify(sourcePath)}, runId: ${JSON.stringify(runId)}, sourceSHA256: ${JSON.stringify(sourceSHA256)},
    siteManifestSHA256: ${JSON.stringify(siteManifestSHA256)}, probeSHA256: ${JSON.stringify(probeSHA256)},
    generation: ${prefix}generation, sequence: ++${prefix}sequence, invalid: ${prefix}invalid,
    counts: [...${prefix}counts] };
}\n`;
  const module = header + body + footer;
  assert.equal(ts.createSourceFile('instrumented.ts', module, ts.ScriptTarget.ESNext, true, ts.ScriptKind.TS).parseDiagnostics.length, 0);
  return { module, sourceSHA256, siteManifest, siteManifestBytes, siteManifestSHA256,
    insertionLedger: { version: 1, offsetUnit: 'UTF-16 code units', header, footer, insertions,
      originalExactlyRecovered: true, notice: 'Removing header, footer and recorded insertions recovers original bytes; this is not a semantics proof.' } };
}

export function generationWrapper(paths, { runId, probeSHA256 }) {
  assert.deepEqual(Object.keys(paths), measuredSources);
  const indexPath = paths['cloud/src/index.ts'];
  return `import worker from ${JSON.stringify(indexPath)};
${measuredSources.map((path, i) => `import { ${prefix}snapshot as snapshot${i} } from ${JSON.stringify(paths[path])};`).join('\n')}
export { ProjectRoom, BillingCoordinator } from ${JSON.stringify(indexPath)};
export default { ...worker, async fetch(request, env, context) {
  const url = new URL(request.url);
  if (url.pathname === ${JSON.stringify(collectorPath)}) {
    if (request.method !== 'GET' || url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || url.search || request.body !== null
      || typeof env.${nonceBinding} !== 'string' || !env.${nonceBinding}
      || request.headers.get('x-scriv-test-coverage') !== env.${nonceBinding}) {
      return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
    }
    return Response.json({ version: 2, runId: ${JSON.stringify(runId)}, probeSHA256: ${JSON.stringify(probeSHA256)},
      modules: [${measuredSources.map((_, i) => `snapshot${i}()`).join(', ')}] }, { headers: { 'Cache-Control': 'no-store' } });
  }
  return worker.fetch(request, env, context);
} };\n`;
}
