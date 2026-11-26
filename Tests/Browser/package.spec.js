import { expect, test } from '@playwright/test';
import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

test('Pages bundle contains only deployable files and a valid size-bounded Wasm executable', async ({ request }) => {
  const paths = await readdir('dist', { recursive: true, withFileTypes: true });
  for (const entry of paths.filter(entry => !entry.isDirectory())) {
    const file = join(entry.parentPath, entry.name);
    expect((await stat(file)).size, file).toBeLessThanOrEqual(25 * 1024 * 1024);
    expect(entry.isFile(), file).toBeTruthy();
    expect(entry.name).not.toMatch(/^(?:_worker\.js|wrangler\.|package(?:-lock)?\.json)/);
  }
  const wasm = await request.get('/munchies.wasm');
  expect(wasm.ok()).toBe(true);
  expect(wasm.headers()['content-type']).toContain('application/wasm');
  expect(WebAssembly.validate(await wasm.body())).toBe(true);
  const headers = await readFile('dist/_headers', 'utf8');
  expect(headers).toMatch(/\/sw\.js\s+Cache-Control:.*\b(?:no-cache|must-revalidate)\b/i);
  expect(headers).toMatch(/\/munchies\.wasm\s+Content-Type:\s*application\/wasm/i);
});

test('manifest has Munchies metadata and real home-screen icons', async ({ request }) => {
  const response = await request.get('/manifest.webmanifest');
  expect(response.ok()).toBe(true);
  const manifest = await response.json();
  expect(manifest).toMatchObject({
    name: 'Munchies',
    short_name: 'Munchies',
    start_url: './',
    scope: './',
    display: 'standalone',
    orientation: 'portrait',
  });
  expect(manifest.theme_color).toMatch(/^#[0-9a-f]{6}$/i);
  for (const dimension of [192, 512]) {
    const size = `${dimension}x${dimension}`;
    const icon = manifest.icons.find(icon => icon.sizes === size);
    expect(icon?.purpose.split(' ')).toContain('any');
    const artwork = await request.get(new URL(icon.src, response.url()).href);
    expect(artwork.ok()).toBe(true);
    expect(artwork.headers()['content-type']).toMatch(/^image\//);
    expect((await artwork.body()).length).toBeGreaterThan(100);
  }
});
