import { writeSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const scenarioPath = /^tests\/e2e\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.mjs$/;
const diagnosticCodes = new Set(['ui-target-ambiguous', 'ui-target-missing', 'ui-wait-timeout',
  'fixture-dependency-missing', 'coverage-session-limit', 'scenario-assertion', 'scenario-error']);
const fd = 3;
const byteLimit = 1024;

function sanitize(raw) {
  if (!diagnosticCodes.has(raw?.code)) return null;
  const result = { code: raw.code }, { path, line } = raw.location ?? {};
  if (typeof path === 'string' && path.length <= 512 && scenarioPath.test(path) && Number.isSafeInteger(line) && line > 0) result.location = { path, line };
  if (raw.code === 'ui-target-missing' && raw.matches === 0
      || raw.code === 'ui-target-ambiguous' && Number.isSafeInteger(raw.matches) && raw.matches > 1) result.matches = raw.matches;
  return result;
}

function diagnosticFor(error) {
  const locations = [];
  let code, matches;
  for (let cause = error, depth = 0; cause && depth < 8; cause = cause.cause, depth++) {
    if (!code) switch (cause.code) {
    case 'SCRIV_UI_TARGET_AMBIGUOUS': code = 'ui-target-ambiguous'; matches = cause.matches; break;
    case 'SCRIV_UI_TARGET_MISSING': code = 'ui-target-missing'; matches = 0; break;
    case 'SCRIV_UI_WAIT_TIMEOUT': code = 'ui-wait-timeout'; break;
    case 'SCRIV_CLI_COVERAGE_SESSION_LIMIT': code = 'coverage-session-limit'; break;
    case 'ERR_MODULE_NOT_FOUND': case 'MODULE_NOT_FOUND': code = 'fixture-dependency-missing'; break;
    case 'ERR_ASSERTION': code = 'scenario-assertion'; break;
    }
    const causeLocations = [];
    for (const frame of String(cause.stack ?? '').split('\n').slice(1, 32)) {
      const match = /(?:\(|\s)(file:\/\/[^\n]+?):([1-9]\d*):\d+\)?$/.exec(frame);
      if (!match) continue;
      try {
        const path = relative(root, fileURLToPath(match[1]));
        if (scenarioPath.test(path)) causeLocations.push({ path, line: Number(match[2]) });
      } catch { /* A frame outside the scenario source carries no diagnostic. */ }
    }
    locations.unshift(...causeLocations);
  }
  // Each cause moves its frames to the front, including eligible shared fixture frames.
  return sanitize({ code: code ?? 'scenario-error', matches, location: locations[0] });
}

export function readScenarioDiagnostic(stream) {
  return new Promise(resolve => {
    let input = Buffer.alloc(0);
    stream.on('data', chunk => {
      if (input.length + chunk.length > byteLimit) { stream.destroy(); resolve(null); return; }
      input = Buffer.concat([input, chunk]);
    });
    stream.once('error', () => resolve(null));
    stream.once('close', () => {
      try { resolve(sanitize(JSON.parse(input.toString('utf8')))); }
      catch { resolve(null); }
    });
  });
}

export const scenarioDiagnosticModule = import.meta.url;
const entry = process.argv[1] && relative(root, process.argv[1]);
if (process.env.SCRIV_E2E_DIAGNOSTIC_FD === String(fd) && entry && scenarioPath.test(entry)) {
  process.once('uncaughtExceptionMonitor', error => {
    try {
      // This dedicated descriptor carries only allowlisted fields. Standard
      // error remains disconnected and the failure retains its normal exit.
      const diagnostic = JSON.stringify(diagnosticFor(error));
      if (Buffer.byteLength(diagnostic) <= byteLimit) writeSync(fd, diagnostic);
    } catch { /* A missing diagnostic channel must not replace the failure. */ }
  });
}
