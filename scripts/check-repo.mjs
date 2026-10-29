import { readFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(await readFile(resolve(root, 'design/manifest.json'), 'utf8'));
let bytes = 0;
for (const image of manifest.images) {
  const data = await readFile(resolve(root, image.path));
  const sha = createHash('sha256').update(data).digest('hex');
  if (sha !== image.sha256 || data.length !== image.bytes) throw new Error(`Design asset changed: ${image.path}`);
  bytes += data.length;
}
if (manifest.images.length !== 25 || bytes !== manifest.total_image_bytes) throw new Error('Design archive is incomplete.');
const fixture = JSON.parse(await readFile(resolve(root, 'design/storyboard-timing-example.json'), 'utf8'));
for (const key of ['main_concept_file', 'storyboard_concept_file']) await stat(resolve(root, 'design', fixture.presentation[key]));
for (const path of ['apps/mac/Package.swift', 'apps/mac/Info.plist', 'apps/mac/Sources/ScrivApp/Services/ResourceBundle.swift', 'cloud/src/index.ts', 'cloud/src/project-room.ts', 'cloud/migrations/0001_identity_teams.sql', '.github/workflows/verify.yml']) await stat(resolve(root, path));
const media = JSON.parse(await readFile(resolve(root, 'apps/mac/Sources/ScrivApp/Resources/SampleImages/provenance.json'), 'utf8'));
for (const image of media.images) {
  const data = await readFile(resolve(root, 'apps/mac/Sources/ScrivApp/Resources/SampleImages', image.file));
  if (createHash('sha256').update(data).digest('hex') !== image.sha256) throw new Error(`Sample image changed: ${image.file}`);
}
console.log(`Verified ${manifest.images.length} original concepts, ${media.images.length} sample frames, timing references and release files.`);
