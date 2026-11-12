#!/usr/bin/env node
/** Static feature navigation only. Never edits Tracer links or measured evidence. */
import { readFile, writeFile, mkdir, rename, realpath, lstat } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { safeSourcePath } from './export-cli-source-manifest.mjs';

const NOTICE = 'MODEL-PROPOSED FEATURE CATEGORIZATION ONLY. Not test mapping, observed execution, measured coverage, or proof of correctness.';
const allowedOptions = {prepare:['--report','--manifest','--out','--taxonomy','--scope','--shards','--prefix'], merge:['--inventory','--taxonomy','--assignment','--proposal','--out'], rebase:['--catalog','--report','--manifest','--scope','--out'], check:['--catalog'], report:['--catalog','--json','--feature','--source']};
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const json = async path => JSON.parse(await readFile(resolve(path), 'utf8'));
const fail = message => { throw new Error(message); };
const lineList = text => { const result = text.split('\n'); if (result.at(-1) === '') result.pop(); return result; };
const args = process.argv.slice(2);
const command = args.shift();
const options = new Map();
for (let i = 0; i < args.length; i++) {
  const key = args[i];
  if (!key.startsWith('--')) fail(`Unexpected argument: ${key}`);
  const value = key === '--json' ? true : args[++i];
  if (value === undefined || String(value).startsWith('--')) fail(`Missing value for ${key}`);
  options.set(key, [...options.get(key) || [], value]);
}
const one = (key, fallback) => {
  const values = options.get(key) || [];
  if (values.length > 1) fail(`Only one ${key} is allowed`);
  return values[0] ?? fallback;
};
const required = key => one(key) ?? fail(`Required: ${key}`);
const many = key => options.get(key) || [];
const save = async (path, data) => {
  path = resolve(path); await mkdir(dirname(path), { recursive: true });
  const temp = `${path}.tmp-${process.pid}`;
  await writeFile(temp, JSON.stringify(data, null, 2) + '\n'); await rename(temp, path);
};
const readSource = async path => {
  if (!safeSourcePath(path) || typeof path !== 'string' || !path || isAbsolute(path) || path.includes('\\') || path.split('/').some(x => x === '.' || x === '..' || !x)) fail(`Unsafe source path: ${path}`);
  let ancestor=root;
  for (const [index,part] of path.split('/').entries()) {
    ancestor=resolve(ancestor,part); const info=await lstat(ancestor);
    if (info.isSymbolicLink() || (index===path.split('/').length-1 ? !info.isFile() : !info.isDirectory())) fail(`Unsupported source file type: ${path}`);
  }
  const absolute = await realpath(resolve(root, path));
  const rel = relative(await realpath(root), absolute);
  if (rel.startsWith(`..${sep}`) || rel === '..' || isAbsolute(rel)) fail(`Source leaves repository: ${path}`);
  const bytes = await readFile(absolute); return { sha256: hash(bytes), lines: lineList(bytes.toString('utf8')) };
};
const taxonomyCheck = taxonomy => {
  if (taxonomy.schemaVersion !== 1 || !Array.isArray(taxonomy.features)) fail('Unsupported taxonomy');
  const ids = new Set();
  for (const feature of taxonomy.features) {
    if (!/^[a-z][a-z0-9-]*$/.test(feature.id) || ids.has(feature.id) || typeof feature.title !== 'string' || !feature.title.trim()) fail('Invalid or duplicate feature');
    ids.add(feature.id);
  }
  return ids;
};
const indexInventory = async inventory => {
  if (inventory.schemaVersion !== 1 || inventory.kind !== 'feature-source-inventory') fail('Unsupported source inventory');
  const files = new Map();
  for (const file of inventory.files) {
    if (files.has(file.path)) fail(`Duplicate inventory file: ${file.path}`);
    const source = await readSource(file.path);
    if (source.sha256 !== file.sha256 || source.lines.length !== file.physicalLines) fail(`Stale source: ${file.path}`);
    const excluded = new Set();
    for (const [start, end] of [...file.blankRanges, ...file.commentRanges]) {
      if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || start > end || end > source.lines.length) fail(`Invalid excluded range: ${file.path}`);
      for (let line = start; line <= end; line++) excluded.add(line);
    }
    if (source.lines.length - excluded.size !== file.includedLines) fail(`Inventory line count mismatch: ${file.path}`);
    files.set(file.path, { ...file, source, excluded });
  }
  return files;
};
const validateRanges = (ranges, files, featureIds, pinned = false) => {
  if (!Array.isArray(ranges)) fail('Missing ranges');
  const occupied = new Map();
  for (const row of ranges) {
    const file = files.get(row.path);
    if (!file || !Number.isInteger(row.start) || !Number.isInteger(row.end) || row.start < 1 || row.end < row.start || row.end > file.physicalLines) fail(`Invalid range: ${row.path}:${row.start}-${row.end}`);
    if (!featureIds.has(row.featureId) || !['low','medium','high'].includes(row.confidence) || typeof row.rationale !== 'string' || !row.rationale.trim()) fail(`Invalid feature/confidence/rationale: ${row.path}`);
    const used = occupied.get(row.path) || new Set();
    for (let line = row.start; line <= row.end; line++) { if (used.has(line)) fail(`Overlapping classification: ${row.path}:${line}`); used.add(line); }
    occupied.set(row.path, used);
    if (pinned && (row.fileSha256 !== file.sha256 || row.spanSha256 !== hash(file.source.lines.slice(row.start - 1,row.end).join('\n')) || row.status !== 'model-proposed')) fail(`Stale or promoted classification: ${row.path}:${row.start}`);
  }
  return occupied;
};
const summarize = (catalog, files) => {
  const totals = { files: files.size, includedLines: 0, categorizedFiles: 0, categorizedIncludedLines: 0, uncategorizedIncludedLines: 0, proposedRanges: catalog.ranges.length };
  const features = new Map(catalog.taxonomy.features.map(x => [x.id,{...x, includedLines:0, ranges:0, files:new Set()}]));
  const perFile = new Map([...files].map(([path,file]) => [path, {path, includedLines:file.includedLines, categorizedIncludedLines:0, uncategorizedRanges:[]} ]));
  const assigned = new Map();
  for (const row of catalog.ranges) {
    const file = files.get(row.path), feature = features.get(row.featureId), used = assigned.get(row.path) || new Set();
    feature.ranges++; feature.files.add(row.path);
    for (let line=row.start; line<=row.end; line++) if (!file.excluded.has(line)) { used.add(line); feature.includedLines++; }
    assigned.set(row.path,used);
  }
  for (const [path,file] of files) {
    const target = perFile.get(path), used = assigned.get(path) || new Set();
    target.categorizedIncludedLines = used.size;
    let start = null;
    for (let line=1;line<=file.physicalLines+1;line++) {
      const missing = line<=file.physicalLines && !file.excluded.has(line) && !used.has(line);
      if (missing && start===null) start=line;
      if (!missing && start!==null) {target.uncategorizedRanges.push([start,line-1]);start=null;}
    }
    totals.includedLines += file.includedLines; totals.categorizedIncludedLines += used.size; if (used.size) totals.categorizedFiles++;
  }
  totals.uncategorizedIncludedLines = totals.includedLines - totals.categorizedIncludedLines;
  return {kind:'feature-classification-report',notice:NOTICE,scope:catalog.inventory.scope,totals,features:[...features.values()].filter(x=>x.ranges).map(x=>({...x,files:x.files.size})),files:[...perFile.values()]};
};
try {
  for (const key of options.keys()) if (!allowedOptions[command]?.includes(key)) fail(`Unsupported option for ${command}: ${key}`);
  if (command === 'prepare') {
    const reportPath=required('--report'), manifestPath=required('--manifest'), output=resolve(required('--out'));
    const report=await json(reportPath), manifest=await json(manifestPath), taxonomy=await json(one('--taxonomy',resolve(root,'docs/testing/feature-taxonomy.json')));
    taxonomyCheck(taxonomy);
    if (report.kind !== 'manual-links' || !Array.isArray(report.files) || !Array.isArray(manifest.files)) fail('Expected Tracer report and exported source manifest');
    const manifestFiles=new Map(manifest.files.map(x=>[x.path,x.sha256]));
    const files=[];
    for (const file of report.files) {
      const source=await readSource(file.path);
      if (manifestFiles.get(file.path)!==source.sha256) fail(`Source differs from manifest: ${file.path}`);
      files.push({path:file.path,sha256:source.sha256,physicalLines:source.lines.length,includedLines:file.lines,blankRanges:file.blankRanges,commentRanges:file.commentRanges});
    }
    const inventory={schemaVersion:1,kind:'feature-source-inventory',scope:one('--scope','Pinned source snapshot'),manifestSha256:hash(await readFile(manifestPath)),reportSha256:hash(await readFile(reportPath)),lineBasis:report.lineBasis,files};
    await indexInventory(inventory);
    const count=Number(one('--shards','4'));
    if (!Number.isInteger(count) || count<1 || count>128) fail('--shards must be 1..128');
    const selected=files.filter(x=>!many('--prefix').length || many('--prefix').some(p=>x.path.startsWith(p)));
    if (!selected.length) fail('No selected source files');
    const shards=Array.from({length:Math.min(count,selected.length)},(_,i)=>({schemaVersion:1,kind:'feature-classification-assignment',id:`shard-${String(i+1).padStart(3,'0')}`,scope:inventory.scope,files:[]}));
    for (const file of selected.sort((a,b)=>b.includedLines-a.includedLines || a.path.localeCompare(b.path))) {
      const shard=shards.reduce((best,s)=>s.files.reduce((n,x)=>n+x.includedLines,0)<best.files.reduce((n,x)=>n+x.includedLines,0)?s:best);
      shard.files.push(file);
    }
    await save(resolve(output,'inventory.json'),inventory); await save(resolve(output,'taxonomy.json'),taxonomy);
    for (const shard of shards) await save(resolve(output,`${shard.id}-assignment.json`),shard);
    console.log(JSON.stringify({kind:'feature-classification-prepared',notice:NOTICE,shards:shards.map(x=>({id:x.id,files:x.files.length,includedLines:x.files.reduce((n,f)=>n+f.includedLines,0)}))},null,2));
  } else if (command === 'merge') {
    const inventory=await json(required('--inventory')), taxonomy=await json(required('--taxonomy'));
    const files=await indexInventory(inventory), ids=taxonomyCheck(taxonomy), ownership=new Map(), assignments=new Map();
    for (const path of many('--assignment')) {
      const item=await json(path);
      if (item.schemaVersion!==1 || item.kind!=='feature-classification-assignment' || typeof item.id!=='string' || assignments.has(item.id)) fail('Invalid or duplicate assignment');
      assignments.set(item.id,item);
      for (const file of item.files) {
        if (!files.has(file.path) || file.sha256!==files.get(file.path).sha256 || file.physicalLines!==files.get(file.path).physicalLines || ownership.has(file.path)) fail(`Invalid or conflicting assignment: ${file.path}`);
        ownership.set(file.path,item.id);
      }
    }
    const ranges=[], proposals=[], seen=new Set(), explicitUnclassified=[];
    for (const path of many('--proposal')) {
      const item=await json(path);
      if (item.schemaVersion!==1 || item.kind!=='feature-classification-proposal' || !assignments.has(item.assignmentId) || seen.has(item.assignmentId) || typeof item.model!=='string' || !item.model.trim()) fail('Invalid, duplicate or unassigned proposal');
      seen.add(item.assignmentId);
      validateRanges(item.ranges,files,ids);
      for (const row of item.ranges) {
        if (ownership.get(row.path)!==item.assignmentId) fail(`Worker exceeded ownership: ${row.path}`);
        const file=files.get(row.path);
        ranges.push({path:row.path,start:row.start,end:row.end,featureId:row.featureId,confidence:row.confidence,rationale:row.rationale,status:'model-proposed',assignmentId:item.assignmentId,fileSha256:file.sha256,spanSha256:hash(file.source.lines.slice(row.start-1,row.end).join('\n'))});
      }
      for (const row of item.unclassified || []) {
        const file=files.get(row.path);
        if (!file || ownership.get(row.path)!==item.assignmentId || !Number.isInteger(row.start) || !Number.isInteger(row.end) || row.start<1 || row.end<row.start || row.end>file.physicalLines || typeof row.reason!=='string' || !row.reason.trim()) fail('Invalid unclassified range');
        if (item.ranges.some(x=>x.path===row.path && x.start<=row.end && row.start<=x.end)) fail('Unclassified range overlaps classification');
        explicitUnclassified.push({...row,assignmentId:item.assignmentId});
      }
      proposals.push({assignmentId:item.assignmentId,model:item.model,sha256:hash(await readFile(path))});
    }
    if (!proposals.length) fail('At least one proposal is required');
    ranges.sort((a,b)=>a.path.localeCompare(b.path)||a.start-b.start);
    validateRanges(ranges,files,ids,true);
    const catalog={schemaVersion:1,kind:'feature-classification-catalog',notice:NOTICE,createdAt:new Date().toISOString(),inventory,taxonomy,proposals,ranges,explicitUnclassified};
    await save(required('--out'),catalog);
    console.log(JSON.stringify(summarize(catalog,files),null,2));
  } else if (command === 'rebase') {
    const oldPath=required('--catalog'), old=await json(oldPath), reportPath=required('--report'), manifestPath=required('--manifest');
    if (old.schemaVersion!==1 || old.kind!=='feature-classification-catalog' || old.notice!==NOTICE) fail('Unsupported catalog');
    const report=await json(reportPath), manifest=await json(manifestPath), ids=taxonomyCheck(old.taxonomy);
    if (report.kind!=='manual-links' || !Array.isArray(report.files) || !Array.isArray(manifest.files)) fail('Expected Tracer report and exported source manifest');
    const manifestFiles=new Map(manifest.files.map(x=>[x.path,x.sha256])), oldFiles=new Map(old.inventory.files.map(x=>[x.path,x]));
    const fresh=[];
    for (const file of report.files) {
      const source=await readSource(file.path);
      if (manifestFiles.get(file.path)!==source.sha256) fail(`Source differs from manifest: ${file.path}`);
      fresh.push({path:file.path,sha256:source.sha256,physicalLines:source.lines.length,includedLines:file.lines,blankRanges:file.blankRanges,commentRanges:file.commentRanges});
    }
    const inventory={schemaVersion:1,kind:'feature-source-inventory',scope:required('--scope'),manifestSha256:hash(await readFile(manifestPath)),reportSha256:hash(await readFile(reportPath)),lineBasis:report.lineBasis,files:fresh};
    const files=await indexInventory(inventory), ranges=[], droppedRanges=[];
    for (const row of old.ranges) {
      const prior=oldFiles.get(row.path), current=files.get(row.path);
      if (!prior || row.fileSha256!==prior.sha256) fail(`Invalid prior range identity: ${row.path}`);
      if (current?.sha256===prior.sha256) ranges.push(row);
      else droppedRanges.push({path:row.path,start:row.start,end:row.end,reason:current?'source-changed-reclassification-required':'outside-new-inventory'});
    }
    validateRanges(ranges,files,ids,true);
    const catalog={...old,createdAt:new Date().toISOString(),inventory,ranges,explicitUnclassified:(old.explicitUnclassified||[]).filter(r=>files.get(r.path)?.sha256===oldFiles.get(r.path)?.sha256),rebase:{previousCatalogSha256:hash(await readFile(oldPath)),retainedRanges:ranges.length,droppedRanges}};
    await save(required('--out'),catalog);
    console.log(JSON.stringify({...summarize(catalog,files),rebase:catalog.rebase},null,2));
  } else if (command === 'check' || command === 'report') {
    const catalog=await json(required('--catalog'));
    if (catalog.schemaVersion!==1 || catalog.kind!=='feature-classification-catalog' || catalog.notice!==NOTICE) fail('Unsupported catalog');
    const files=await indexInventory(catalog.inventory), ids=taxonomyCheck(catalog.taxonomy);
    validateRanges(catalog.ranges,files,ids,true);
    const proposalIds = new Set();
    for (const p of catalog.proposals || []) { if (proposalIds.has(p.assignmentId) || typeof p.model!=='string' || !/^[a-f0-9]{64}$/.test(p.sha256)) fail('Invalid proposal provenance'); proposalIds.add(p.assignmentId); }
    if (catalog.ranges.some(r=>!proposalIds.has(r.assignmentId))) fail('Missing range proposal provenance');
    const report=summarize(catalog,files);
    const feature = one('--feature'), source = one('--source');
    if (feature && source) fail('Use only one of --feature or --source');
    if (feature && !ids.has(feature)) fail(`Unknown feature: ${feature}`);
    if (source && !files.has(source)) fail(`Unknown source: ${source}`);
    if (feature || source) report.selection = {feature:feature || null, source:source || null, ranges:catalog.ranges.filter(r=>feature ? r.featureId===feature : r.path===source)};
    if (command==='check') console.log(JSON.stringify({ok:true,notice:NOTICE,totals:report.totals},null,2));
    else if (one('--json',false)) console.log(JSON.stringify(report,null,2));
    else {
      console.log(NOTICE); console.log(`Scope: ${report.scope}`);
      console.log(`${report.totals.categorizedIncludedLines}/${report.totals.includedLines} included lines categorized; ${report.totals.uncategorizedIncludedLines} remain uncategorized.`);
      if (report.selection) for (const r of report.selection.ranges) console.log(`${r.path}:${r.start}-${r.end} | ${r.featureId} | ${r.confidence} | ${r.rationale}`);
      else for (const f of report.features.sort((a,b)=>b.includedLines-a.includedLines)) console.log(`${f.includedLines} lines | ${f.id} | ${f.title}`);
    }
  } else {
    console.log(`Feature categorization, separate from Tracer test evidence.\n${NOTICE}\n\nprepare --report FILE --manifest FILE --out DIR [--taxonomy FILE] [--scope TEXT] [--shards N] [--prefix PATH ...]\nmerge --inventory FILE --taxonomy FILE --assignment FILE ... --proposal FILE ... --out FILE\nrebase --catalog FILE --report FILE --manifest FILE --scope TEXT --out FILE\ncheck --catalog FILE\nreport --catalog FILE [--json] [--feature ID | --source PATH]`);
    if (command && command!=='--help') process.exitCode=2;
  }
} catch (error) { console.error(`Feature catalog: ${error.message}`); process.exitCode=1; }
