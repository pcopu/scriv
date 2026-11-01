import test from 'node:test'; import assert from 'node:assert/strict'; import { readFile } from 'node:fs/promises';
const read = p => readFile(new URL('../' + p, import.meta.url), 'utf8');
test('signed app channel, signed feed channel, and explicit publisher channel agree', async () => {
  const plugin = await read('apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m');
  assert.match(plugin, /allowedChannelsForUpdater/); assert.match(plugin, /item.channel isEqual/);
  assert.match(plugin, /objectForInfoDictionaryKey:@"ScrivUpdateChannel"/);
  assert.doesNotMatch(plugin, /NSUserDefaults.*channel/);
  const release = await read('updates/scripts/release.py');
  assert.match(release, /<sparkle:channel>/); assert.match(release, /confirmed_channel == channel/);
  assert.match(release, /validate_feed_manifest\(feed, manifest\)/);
  assert.match(release, /old.get\('channel'\) == channel/);
});
test('archive keeps native Sparkle embedding fix and passes explicit channel build settings', async () => {
  const archive = await read('scripts/archive-catalyst-release.sh');
  assert.match(archive, /SCRIV_UPDATE_CHANNEL="\$SCRIV_UPDATE_CHANNEL"/);
  assert.match(archive, /SCRIV_UPDATE_FEED_URL="\$SCRIV_UPDATE_FEED_URL"/);
  assert.doesNotMatch(archive, /generate_keys|security add|disable-library-validation|spctl --master-disable/);
  const generator = await read('scripts/generate-catalyst-project.py');
  assert.doesNotMatch(generator, /add\('SparkleEmbed'/);
});
test('acceptance checks do not install, launch, publish, or claim UI behavior from static bytes', async () => {
  const check = await read('updates/scripts/acceptance.py');
  assert.match(check, /'installed': False/); assert.match(check, /app-initiated download provenance/);
  assert.match(check, /new_process\['pid'\] !=|old_process\['pid'\] != new_process\['pid'\]/);
  assert.match(check, /NoRedirect/); assert.match(check, /os.O_EXCL, 0o600/);
  assert.doesNotMatch(check, /release.publish\(|notarytool.*submit|generate_keys|osascript/);
});

test('acceptance public metadata is exact and opt-in without changing stable defaults', async () => {
  const { execFileSync } = await import('node:child_process');
  const { fileURLToPath } = await import('node:url');
  const configPath = fileURLToPath(new URL('../updates/acceptance-20261031.env', import.meta.url));
  const values = execFileSync('/bin/bash', ['--noprofile', '--norc', '-c', 'source "$1"; printf "%s\\n" "$SCRIV_TEAM_ID" "$SCRIV_UPDATE_PUBLIC_KEY" "$SCRIV_SPARKLE_KEY_ACCOUNT" "$SCRIV_UPDATE_CHANNEL"', 'bash', configPath], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin' } }).trim().split('\n');
  assert.deepEqual(values, ['QF9687U3H9', '/32UNmbO5PdePvyUoZQnDzrpnC1c4PCayL0akOaDalU=', 'app.scriv.updates', 'acceptance-20261031']);
  assert.equal(Buffer.from(values[1], 'base64').length, 32);
  const config = await read('updates/acceptance-20261031.env');
  assert.equal(config.split('\n').filter(line => line && !line.startsWith('#')).length, 4);
  const generator = await read('scripts/generate-catalyst-project.py');
  assert.match(generator, /SCRIV_UPDATE_CHANNEL.*stable/);
  assert.doesNotMatch(generator, /acceptance-20261031|app\.scriv\.updates/);
  assert.doesNotMatch(await read('scripts/build-catalyst.sh'), /acceptance-20261031\.env/);
  const release = await read('updates/scripts/release.py');
  assert.match(release, /add_argument\('--key-account', required=True/);
  const runbook = await read('docs/signed-update-acceptance.md');
  assert.doesNotMatch(runbook, /scriv-release|THE_APPROVED_REAL_PUBLIC_PIN|generate_keys --account/);
});
