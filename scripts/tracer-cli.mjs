#!/usr/bin/env node
/** Resolve an explicitly selected installed Tracer, never download or install it. */
import { spawn } from 'node:child_process';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const configured = process.env.SCRIV_TRACER_CLI;
if (configured && (!isAbsolute(configured) || /[\x00-\x1f\x7f]/.test(configured))) {
  console.error('SCRIV_TRACER_CLI must be an absolute trusted executable or .mjs entrypoint.');
  process.exitCode = 2;
} else {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const executable = configured?.endsWith('.mjs') ? process.execPath : configured || 'tracer';
  const prefix = configured?.endsWith('.mjs') ? [configured] : [];
  const child = spawn(executable, [...prefix, '--root', root, ...process.argv.slice(2)], {
    cwd: root, stdio: 'inherit', shell: false, env: { ...process.env, TRACER_NO_UPDATE: '1' },
  });
  const interrupt = signal => { if (child.pid) child.kill(signal); };
  const onInt = () => interrupt('SIGINT'); const onTerm = () => interrupt('SIGTERM');
  process.on('SIGINT', onInt); process.on('SIGTERM', onTerm);
  child.once('error', () => { console.error('Tracer could not start. Install Tracer or set SCRIV_TRACER_CLI to its trusted absolute entrypoint.'); process.exitCode = 2; });
  child.once('exit', (code, signal) => {
    process.removeListener('SIGINT', onInt); process.removeListener('SIGTERM', onTerm);
    process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 1);
  });
}
