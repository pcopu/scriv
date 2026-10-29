import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, chmod, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const script = new URL('../scripts/smoke-codex-runtime.py', import.meta.url).pathname;
async function fixture(mode) {
  const root = await mkdtemp(path.join(tmpdir(), 'scriv-codex-fixture-'));
  const executable=path.join(root,'fake-codex'), report=path.join(root,'result.json');
  await writeFile(executable, `#!/usr/bin/env python3
import json,os,sys,time
if '--version' in sys.argv: print('codex-cli 0.0.1-test'); sys.exit(0)
assert not any(k in os.environ for k in ['OPENAI_API_KEY','CHATGPT_TOKEN','CODEX_AUTH_JSON'])
assert os.environ['CODEX_HOME'].startswith(os.environ['HOME']+'/')
for line in sys.stdin:
 v=json.loads(line)
 if 'id' not in v: continue
 if ${JSON.stringify(mode)} == 'timeout': time.sleep(10)
 result={}
 if v['method']=='account/read': result={'account':None if ${JSON.stringify(mode)} != 'unexpected-account' else {'type':'fixture-do-not-copy'}}
 if v['method']=='model/list': result={'data':[{'model':'fixture-do-not-copy'}]}
 print(json.dumps({'id':v['id'],'result':result}),flush=True)
`);
  await chmod(executable,0o755);
  const result=spawnSync('python3',[script,executable,'--report',report,'--timeout',mode==='timeout'?'1':'5'],{encoding:'utf8',env:{...process.env,OPENAI_API_KEY:'fixture-must-not-be-forwarded',CHATGPT_TOKEN:'fixture-must-not-be-forwarded',CODEX_AUTH_JSON:'fixture-must-not-be-forwarded'}});
  const evidence=JSON.parse(await readFile(report,'utf8'));
  return {result,evidence,close:()=>rm(root,{recursive:true,force:true})};
}
test('isolated Codex smoke passes handshake without inheriting credentials or logging model/account data',async()=>{
  const f=await fixture('success');try{
    assert.equal(f.result.status,0);assert.equal(f.evidence.passed,true);assert.equal(f.evidence.modelListCount,1);
    assert.equal(f.evidence.ownedChildStopped,true);assert.equal(f.evidence.authenticated,false);assert.equal(f.evidence.nativeControllerTested,false);
    assert.doesNotMatch(f.result.stdout,/fixture-do-not-copy|fixture-must-not-be-forwarded/);
  }finally{await f.close();}
});
test('isolated Codex smoke rejects unexpected account state and still stops its child',async()=>{
  const f=await fixture('unexpected-account');try{
    assert.equal(f.result.status,1);assert.equal(f.evidence.passed,false);assert.equal(f.evidence.ownedChildStopped,true);
    assert.match(f.evidence.error,/Expected a signed-out account/);assert.doesNotMatch(f.result.stdout,/fixture-do-not-copy/);
  }finally{await f.close();}
});
test('isolated Codex smoke times out an unresponsive child and reports failure rather than a false pass',async()=>{
  const f=await fixture('timeout');try{
    assert.equal(f.result.status,1);assert.equal(f.evidence.passed,false);assert.equal(f.evidence.ownedChildStopped,true);assert.match(f.evidence.error,/timed out/);
  }finally{await f.close();}
});
