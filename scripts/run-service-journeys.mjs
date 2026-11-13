#!/usr/bin/env node
/** Fixed black-box service journeys. Never imports an application implementation. */
import { spawn } from 'node:child_process';
import { serviceJourneys as journeys, serviceHelp } from './service-catalog.mjs';
import { dirname, resolve, relative, join } from 'node:path';
import { mkdir, realpath, lstat } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export async function main(args = process.argv.slice(2)) {
  if (args.length === 1 && args[0] === '--help') {
    console.log(serviceHelp);
    return 0;
  }
  if (args.length === 1 && args[0] === '--list') {
    console.log(JSON.stringify({ schemaVersion: 1, kind: 'local-service-cli-scenario-catalog', scenarios: journeys }, null, 2));
    return 0;
  }
  if (args.length > 1 || (args.length && !journeys.some(row => row.id === args[0]))) throw new Error('invalid-service-scenario');
  const selected = args.length ? journeys.filter(row => row.id === args[0]) : journeys;
  let coverageRoot;
  if (process.env.SCRIV_SERVICE_COVERAGE_DIR && selected.some(journey => journey.id !== 'updates')) {
    coverageRoot = process.env.SCRIV_SERVICE_COVERAGE_DIR;
    if (coverageRoot !== resolve(coverageRoot)) throw new Error('Service coverage output must be absolute');
    const parent = dirname(coverageRoot), info = await lstat(parent);
    if (await realpath(parent) !== parent || !info.isDirectory() || info.uid !== process.getuid() || (info.mode & 0o022)) throw new Error('Service coverage parent must be canonical and private');
    const distance = relative(root, coverageRoot), reverse = relative(coverageRoot, root);
    if (!(distance === '..' || distance.startsWith('../')) || !(reverse === '..' || reverse.startsWith('../'))) throw new Error('Service coverage output must be outside source');
    await mkdir(coverageRoot, { mode: 0o700 });
  }
  for (const journey of selected) {
    // Each existing journey owns its process group, bounded deadline, isolated
    // temporary state and cleanup. Forward cancellation so that owner can stop it.
    const child = spawn(process.execPath, [resolve(root, journey.path)], { cwd: root, stdio: 'inherit', shell: false,
      env: { ...process.env, ...(coverageRoot && journey.id !== 'updates' ? { SCRIV_SERVICE_COVERAGE_DIR: join(coverageRoot, journey.id) } : {}) } });
    const onInt = () => child.kill('SIGINT'); const onTerm = () => child.kill('SIGTERM');
    process.on('SIGINT', onInt); process.on('SIGTERM', onTerm);
    let interrupted = false;
    const recordInterrupt = () => { interrupted = true; };
    process.on('SIGINT', recordInterrupt); process.on('SIGTERM', recordInterrupt);
    const result = await new Promise(resolve => {
      child.once('error', () => resolve({ code: null, error: 'spawn-failed' }));
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });
    process.removeListener('SIGINT', onInt); process.removeListener('SIGTERM', onTerm);
    process.removeListener('SIGINT', recordInterrupt); process.removeListener('SIGTERM', recordInterrupt);
    if (interrupted || result.code !== 0) {
      console.error(`Service CLI journey failed: ${journey.id}; remaining journeys were not run.`);
      return 1;
    }
  }
  console.log(`PASS ${selected.length}/${selected.length} selected local service CLI journeys; native scenarios executed: 0.`);
  return 0;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().then(code => { process.exitCode = code; }).catch(error => { console.error(error.message); process.exitCode = 2; });
