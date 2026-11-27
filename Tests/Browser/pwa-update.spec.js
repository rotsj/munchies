import { expect, test } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';

const progressKey = 'munchies.pwa.progress.v1';
const offlineStatus = "You're offline. Connect to check for updates.";

async function openHomeSettings(page, url = '/') {
  await page.goto(url);
  await page.getByRole('button', { name: 'Settings', exact: true }).tap();
  const settings = page.getByRole('dialog', { name: 'Settings' });
  await expect(settings).toBeVisible();
  return settings;
}

// Use real service-worker registrations. Change which build the origin serves
// so every browser makes its own request for the replacement worker and assets.
async function serveReleases(baseURL) {
  const [worker, html] = await Promise.all([readFile('dist/sw.js', 'utf8'), readFile('dist/index.html', 'utf8')]);
  const initialBuild = worker.match(/const BUILD_ID = "([a-f0-9]{20})"/)[1];
  const nextBuild = (initialBuild[0] === 'a' ? 'b' : 'a') + initialBuild.slice(1);
  let servedBuild = initialBuild;
  let incomplete = false;
  const server = createServer(async (req, res) => {
    const { pathname } = new URL(req.url, baseURL);
    const headers = { 'cache-control': 'no-store' };
    const send = (type, body) => res.writeHead(200, { ...headers, 'content-type': type }).end(body);
    if (pathname === '/sw.js') return send('text/javascript', worker.replace(initialBuild, servedBuild));
    if (pathname === '/' || pathname === '/index.html') return send('text/html', html.replace(initialBuild, servedBuild));
    if (pathname === '/release.json') return send('application/json', JSON.stringify({ build: servedBuild }));
    if (incomplete && pathname === '/styles.css') return res.writeHead(503, headers).end();
    try {
      const original = new URL(baseURL);
      original.pathname = pathname;
      const asset = await fetch(original);
      const body = Buffer.from(await asset.arrayBuffer());
      res.writeHead(asset.status, { ...headers, 'content-type': asset.headers.get('content-type') }).end(body);
    } catch {
      res.writeHead(502, headers).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}/`,
    initialBuild,
    nextBuild,
    publish({ missingAsset = false } = {}) {
      servedBuild = nextBuild;
      incomplete = missingAsset;
    },
    async close() {
      const closed = new Promise(resolve => server.close(resolve));
      server.closeAllConnections();
      await closed;
    },
  };
}

test('home Settings checks the current version and gives a retryable offline result', async ({ page, context }) => {
  const settings = await openHomeSettings(page);
  const check = settings.getByRole('button', { name: 'Check for updates' });
  const status = settings.getByRole('status');
  await expect(check).toBeVisible();
  await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
  await check.tap();
  await expect(status).toHaveText('Munchies is up to date.');

  await context.setOffline(true);
  await check.tap();
  await expect(status).toHaveText(offlineStatus);
  await expect(check).toBeEnabled();

  await context.setOffline(false);
  await check.tap();
  await expect(status).toHaveText('Munchies is up to date.');

  await settings.getByRole('button', { name: 'Close settings' }).tap();
  await page.getByRole('button', { name: 'Play Craving Trail' }).tap();
  await page.getByRole('button', { name: 'Pause' }).tap();
  await expect(settings).toBeVisible();
  await expect(check).toBeHidden();
});

for (const alreadyActive of [false, true]) {
  test(`home Settings applies a ${alreadyActive ? 'background-installed' : 'newly published'} update and retains progress`, async ({ page, context, baseURL }) => {
    const server = await serveReleases(baseURL);
    try {
      await page.addInitScript(() => Object.defineProperty(navigator, 'standalone', { value: true }));
      const settings = await openHomeSettings(page, server.url);
      const check = settings.getByRole('button', { name: 'Check for updates' });
      const status = settings.getByRole('status');
      const build = page.locator('meta[name="munchies-build"]');
      await expect(check).toBeVisible();
      await expect(build).toHaveAttribute('content', server.initialBuild);
      await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);

      await settings.getByRole('checkbox', { name: 'Screen Shake' }).uncheck();
      await page.evaluate(key => {
        const progress = JSON.parse(localStorage.getItem(key));
        localStorage.setItem(key, JSON.stringify({ ...progress, highScore: 8420 }));
        window.testDocument = true;
      }, progressKey);

      if (alreadyActive) {
        server.publish();
        await page.evaluate(async () => (await navigator.serviceWorker.getRegistration()).update());
        await expect.poll(() => page.evaluate(async () => (await (await fetch('./release.json')).json()).build)).toBe(server.nextBuild);
      } else {
        server.publish({ missingAsset: true });
        await check.tap();
        await expect(status).toHaveText("Couldn't check for updates. Try again.");
        await expect(build).toHaveAttribute('content', server.initialBuild);
        await expect(check).toBeEnabled();
        await expect.poll(() => page.evaluate(() => caches.keys())).toEqual([`munchies-pwa-${server.initialBuild}`]);
        server.publish();
      }

      await check.tap();
      const update = settings.getByRole('button', { name: 'Update now' });
      await expect(update).toBeEnabled();
      await expect(status).toHaveText('Update ready. Restart Munchies to use it.');
      await expect(build).toHaveAttribute('content', server.initialBuild);
      expect(await page.evaluate(() => window.testDocument)).toBe(true);

      await context.setOffline(true);
      await Promise.all([page.waitForEvent('load'), update.tap()]);
      await expect(build).toHaveAttribute('content', server.nextBuild);
      await expect(page.getByRole('button', { name: 'Play Craving Trail' })).toBeEnabled();
      await expect(page.locator('#home-highscore')).toHaveText('8420');
      await page.getByRole('button', { name: 'Settings', exact: true }).tap();
      await expect(settings.getByRole('checkbox', { name: 'Screen Shake' })).not.toBeChecked();
    } finally {
      await server.close();
    }
  });
}
