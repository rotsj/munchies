import { createHash } from 'node:crypto';
import { readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join, relative } from 'node:path';

const root = process.argv[2];
const files = (await readdir(root, { withFileTypes: true, recursive: true }))
  .filter(entry => !entry.isDirectory())
  .map(entry => relative(root, join(entry.parentPath, entry.name)))
  .sort();
const hash = createHash('sha256');
const assets = ['./', './release.json'];
for (const file of files) {
  const path = join(root, file);
  const info = await stat(path);
  if (info.size > 25 * 1024 * 1024) {
    throw new Error(`${file} is ${info.size} bytes and exceeds the Cloudflare Pages 25 MiB asset limit`);
  }
  if (file === 'sw.js') continue;
  hash.update(file).update('\0').update(await readFile(path));
  if (file !== '_headers') assets.push(`./${file}`);
}
const workerPath = join(root, 'sw.js');
const worker = await readFile(workerPath, 'utf8');
const release = hash.update(worker).digest('hex').slice(0, 20);
const indexPath = join(root, 'index.html');
const html = await readFile(indexPath, 'utf8');
await Promise.all([
  writeFile(workerPath, worker
    .replace('/* BUILD_ID */ "dev"', JSON.stringify(release))
    .replace('/* PRECACHE_ASSETS */ []', JSON.stringify(assets, null, 2))),
  writeFile(indexPath, html.replace('name="munchies-build" content="dev"', `name="munchies-build" content="${release}"`)),
  writeFile(join(root, 'release.json'), `${JSON.stringify({ build: release })}\n`),
]);
