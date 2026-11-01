#!/usr/bin/env node
// Logical-operation/reference harness, NOT a UIKit benchmark or a Swift execution.
// Mirrors the source's rail geometry/overlap calculations to quantify repeated
// derived work and compare outputs. Native timings live in PlaybackResponsivenessTests.
import { pathToFileURL } from 'node:url';

export function fixture(count) {
  const entries = Array.from({ length: count }, (_, index) => ({
    id: `entry-${index}`, order: index, direction: index % 6 === 0,
    duration: index % 6 === 0 ? 0 : 2000, coverage: index % 6 === 0 ? 12000 : 0,
  }));
  const frames = new Map(entries.map((entry, index) => [entry.id, { minY: index * 140, maxY: index * 140 + 120 }]));
  return { entries, frames };
}

function railPosition(time, rows) {
  if (!rows.length) return 0;
  const first = rows[0], last = rows.at(-1);
  if (time <= first.start) return first.anchor;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index];
    if (time <= row.start) return row.anchor;
    const end = row.start + Math.max(0, row.duration);
    if (row.duration <= 0 || time > end) continue;
    const bottom = index + 1 < rows.length ? rows[index + 1].anchor : row.bottom;
    return row.anchor + (time - row.start) / row.duration * Math.max(0, bottom - row.anchor);
  }
  return last.bottom;
}

export function modelLayout({ entries, frames, anchorOffset = 26, rowSpacing = 23, drag = null }, snapshot) {
  const counters = { geometryBuilds: 0, startLookups: 0, endpointCalls: 0 };
  const ordered = [...entries].sort((a, b) => a.order - b.order || a.id.localeCompare(b.id));
  function start(id) {
    counters.startLookups += 1;
    let clock = 0;
    for (const entry of ordered) { if (entry.id === id) return clock; clock += entry.duration; }
    return 0;
  }
  function geometry() {
    counters.geometryBuilds += 1;
    return entries.filter(entry => frames.has(entry.id)).map(entry => ({
      start: start(entry.id), duration: entry.duration,
      anchor: frames.get(entry.id).minY + anchorOffset, bottom: frames.get(entry.id).maxY + rowSpacing,
    }));
  }
  function endpoint(entry, rows) {
    counters.endpointCalls += 1;
    const value = drag?.id === entry.id ? drag.currentY : railPosition(start(entry.id) + entry.coverage, rows ?? geometry());
    return Math.max((frames.get(entry.id)?.minY ?? 0) + anchorOffset + 12, value);
  }
  const directions = entries.filter(entry => entry.direction);
  const rows = snapshot && directions.length ? geometry() : null;
  const endpoints = snapshot ? new Map(directions.map(entry => [entry.id, endpoint(entry, rows)])) : null;
  const result = [];
  for (const entry of directions) {
    if (!frames.has(entry.id)) continue;
    const end = snapshot ? endpoints.get(entry.id) : endpoint(entry);
    const overlap = directions.filter(candidate => {
      const frame = frames.get(candidate.id);
      if (!frame) return false;
      return snapshot
        ? end >= frame.minY + 12 && end <= endpoints.get(candidate.id) + 14
        : endpoint(entry) >= frame.minY + 12 && endpoint(entry) <= endpoint(candidate) + 14;
    }).map(candidate => candidate.id);
    result.push({ id: entry.id, end, overlap });
  }
  return { result, counters };
}

export function report(counts = [6, 24, 96, 192]) {
  return counts.map(entries => {
    const input = fixture(entries), before = modelLayout(input, false), after = modelLayout(input, true);
    return {
      entries, directions: input.entries.filter(entry => entry.direction).length,
      before: before.counters, candidate: after.counters,
      sceneWordTrackBuildsPerScriptRefresh: { before: entries, candidate: 1 },
      outputEquivalent: JSON.stringify(before.result) === JSON.stringify(after.result),
    };
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(JSON.stringify({
    evidence: 'Synthetic logical operation counts; not native timings, compiler validation, or proof of the observed CUA timeout cause',
    results: report(),
  }, null, 2));
}
