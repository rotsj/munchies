import { expect, test } from '@playwright/test';

const progressKey = 'munchies.pwa.progress.v1';
const emptyProgress = {
  highScore: 0,
  cumulativeScore: 0,
  totalPuppiesRescued: 0,
  totalBigMacsMatched: 0,
  totalTeidoSurgesTriggered: 0,
  totalFiestaBombsCreated: 0,
  bestCascadeCombo: 0,
  totalSnoreBubblesPopped: 0,
  highestTierReached: 1,
  soundEffectsEnabled: true,
  goofySnoreSoundsEnabled: true,
  screenShakeEnabled: true,
  selectedBackdrop: 'cozyDefault',
};

async function instrument(page, { sound = false, progress } = {}) {
  await page.addInitScript(({ sound, progress, progressKey }) => {
    if (progress && localStorage.getItem(progressKey) === null) {
      localStorage.setItem(progressKey, JSON.stringify(progress));
    }

    // Drive the same opening board across browsers through WASI's normal random source.
    let rng = 341856;
    crypto.getRandomValues = bytes => {
      for (let i = 0; i < bytes.length; i++) {
        rng ^= rng << 13;
        rng ^= rng >>> 17;
        rng ^= rng << 5;
        bytes[i] = rng;
      }
      return bytes;
    };

    // Observe the actual Canvas 2D calls. The Swift app has no test-only game API.
    const sprites = new WeakMap();
    const probe = window.munchiesProbe = { frame: [], contexts: 0, resumes: 0, tones: [] };
    const canvas = CanvasRenderingContext2D.prototype;
    const clear = canvas.clearRect;
    canvas.clearRect = function (...args) {
      if (this.canvas.id === 'board-canvas') probe.frame = [];
      return clear.apply(this, args);
    };
    const draw = canvas.drawImage;
    canvas.drawImage = function (source, ...args) {
      const kind = source.src?.match(/\/tile-([a-zA-Z]+)\.svg$/)?.[1] ?? sprites.get(source);
      if (kind) {
        if (this.canvas.id === 'board-canvas') {
          const transform = this.getTransform();
          const dpr = devicePixelRatio;
          probe.frame.push({
            kind, x: transform.e / dpr, y: transform.f / dpr,
            scale: Math.hypot(transform.a, transform.b) / dpr,
            rasterized: source instanceof HTMLCanvasElement || source instanceof ImageBitmap,
          });
        } else {
          sprites.set(this.canvas, kind);
        }
      }
      return draw.call(this, source, ...args);
    };

    if (sound) {
      window.AudioContext = class {
        constructor() { probe.contexts++; }
        currentTime = 0;
        state = 'suspended';
        destination = {};
        resume() { this.state = 'running'; probe.resumes++; return Promise.resolve(); }
        createOscillator() {
          const tone = {};
          return {
            frequency: {
              setValueAtTime: frequency => { tone.frequency = frequency; },
              exponentialRampToValueAtTime() {},
            },
            connect: node => { tone.gain = node.peakGain; },
            start: time => { tone.start = time; },
            stop: time => { probe.tones.push({ ...tone, stop: time }); },
          };
        }
        createGain() {
          const node = { peakGain: 0, connect() {} };
          node.gain = {
            setValueAtTime() {},
            linearRampToValueAtTime: gain => { node.peakGain = gain; },
            exponentialRampToValueAtTime() {},
          };
          return node;
        }
      };
    }
  }, { sound, progress, progressKey });
}

async function frame(page) {
  await expect.poll(() => page.evaluate(() => window.munchiesProbe.frame.length)).toBe(72);
  return page.evaluate(() => {
    const copies = [...window.munchiesProbe.frame];
    copies.sort((a, b) => a.y - b.y || a.x - b.x);
    return Array.from({ length: 9 }, (_, row) => copies.slice(row * 8, (row + 1) * 8));
  });
}

function findSwap(board, { valid = true, preferredKind, axis, longest = false } = {}) {
  const kinds = board.map(row => row.map(tile => tile.kind));
  const partners = axis === 'x' ? [[0, 1]] : axis === 'y' ? [[1, 0]] : [[0, 1], [1, 0]];
  let best, bestSize = 0;
  for (let r = 0; r < 9; r++) {
    for (let c = 0; c < 8; c++) {
      for (const [dr, dc] of partners) {
        if (r + dr >= 9 || c + dc >= 8) continue;
        const after = kinds.map(row => row.slice());
        [after[r][c], after[r + dr][c + dc]] = [after[r + dr][c + dc], after[r][c]];
        const matches = [];
        for (const [row, col] of [[r, c], [r + dr, c + dc]]) {
          const kind = after[row][col];
          for (const [dy, dx] of [[0, 1], [1, 0]]) {
            let length = 1;
            for (const sign of [-1, 1]) {
              let distance = sign;
              while (after[row + distance * dy]?.[col + distance * dx] === kind) {
                length++;
                distance += sign;
              }
            }
            if (length >= 3) matches.push({ kind, length });
          }
        }
        if (valid ? matches.some(({ kind }) => !preferredKind || kind === preferredKind) : matches.length === 0) {
          const move = [board[r][c], board[r + dr][c + dc]];
          if (!longest) return move;
          const size = matches.reduce((sum, match) => sum + match.length, 0);
          if (size > bestSize) {
            best = move;
            bestSize = size;
          }
        }
      }
    }
  }
  if (best) return best;
  throw new Error('No canvas cells form the requested swap');
}

async function openGame(page) {
  await page.goto('/');
  await page.getByRole('button', { name: 'Play Endless Run' }).tap();
  await expect(page.locator('#screen-game')).toBeVisible();
}

async function canvasPoints(page, tiles) {
  const bounds = await page.locator('#board-canvas').boundingBox();
  return tiles.map(({ x, y }) => ({ x: x + bounds.x, y: y + bounds.y }));
}

async function readProgress(page) {
  return page.evaluate(key => JSON.parse(localStorage.getItem(key)), progressKey);
}

async function controlAnimationFrames(page) {
  await page.evaluate(() => {
    const pending = new Map();
    let requestId = 0;
    let frameTime = performance.now();
    window.requestAnimationFrame = callback => {
      pending.set(++requestId, callback);
      return requestId;
    };
    window.cancelAnimationFrame = id => pending.delete(id);
    window.munchiesProbe.hasPendingFrame = () => pending.size > 0;
    window.munchiesProbe.advanceFrames = count => {
      for (let i = 0; i < count; i++) {
        // Use the renderer's largest supported frame delta.
        frameTime += 50;
        const callbacks = [...pending.values()];
        pending.clear();
        for (const callback of callbacks) callback(frameTime);
      }
    };
  });
  await expect.poll(() => page.evaluate(() => window.munchiesProbe.hasPendingFrame()), {
    message: 'The Wasm app schedules another animation frame',
  }).toBe(true);
}

async function advanceAnimationUntil(locator, attribute, value) {
  const actual = await locator.evaluate((element, { attribute, value }) => {
    // Check every frame so a brief reaction cannot pass between observations.
    for (let frame = 0; frame < 200 && element.getAttribute(attribute) !== value; frame++) {
      window.munchiesProbe.advanceFrames(1);
    }
    return element.getAttribute(attribute);
  }, { attribute, value });
  expect(actual, `${attribute} after advancing up to 200 animation frames`).toBe(value);
}

test('SwiftWasm boots with no external requests and draws an 8 by 9 Retina board between safe HUD zones', async ({ page, request, baseURL }) => {
  await instrument(page);
  const runtimeErrors = [], externalRequests = [];
  page.on('pageerror', error => runtimeErrors.push(String(error)));
  page.on('request', req => {
    if (!req.url().startsWith(baseURL)) externalRequests.push(req.url());
  });
  await openGame(page);
  const board = await frame(page);
  expect(board.every(row => row.length === 8)).toBeTruthy();
  expect(new Set(board.flat().map(tile => Math.round(tile.x))).size).toBe(8);
  expect(new Set(board.flat().map(tile => Math.round(tile.y))).size).toBe(9);
  expect(new Set(board.flat().map(tile => tile.kind))).toEqual(
    new Set(['cupcake', 'teido', 'hermanosTaco', 'partillePoke', 'biltemaCombo', 'bigMac'])
  );
  expect(board.flat().every(tile => tile.rasterized)).toBeTruthy();
  expect(runtimeErrors).toEqual([]);
  expect(externalRequests).toEqual([]);
  await expect(page).toHaveTitle('Munchies');
  await expect(page.locator('meta[name=viewport]')).toHaveAttribute('content', /maximum-scale=1\.0, user-scalable=no, viewport-fit=cover/);
  await expect(page.locator('meta[name=apple-mobile-web-app-capable]')).toHaveAttribute('content', 'yes');
  await expect(page.locator('meta[name=apple-mobile-web-app-status-bar-style]')).toHaveAttribute('content', 'black-translucent');
  await expect(page.locator('link[rel=apple-touch-icon]')).toHaveAttribute('href', /\.png$/);
  const css = await (await request.get('/styles.css')).text();
  expect(css).toMatch(/padding-top:.*env\(safe-area-inset-top\)/);
  expect(css).toMatch(/padding-bottom:\s*max\(24px, env\(safe-area-inset-bottom\)\)/);

  const layout = async () => page.evaluate(() => {
    const canvas = document.querySelector('#board-canvas');
    const cs = getComputedStyle(document.body);
    return {
      height: innerHeight,
      paddingBottom: getComputedStyle(document.querySelector('#screen-game')).paddingBottom,
      screenHeight: document.querySelector('#screen-game').getBoundingClientRect().height,
      canvas: canvas.getBoundingClientRect().toJSON(), backing: [canvas.width, canvas.height],
      hud: document.querySelector('.hud-header').getBoundingClientRect().toJSON(),
      footer: document.querySelector('.thumb-dock').getBoundingClientRect().toJSON(),
      overflow: cs.overflow, touch: cs.touchAction, selection: cs.userSelect,
      ratio: devicePixelRatio, scroll: [scrollX, scrollY],
    };
  });
  for (const heightReduction of [0, 140]) {
    if (heightReduction) {
      const size = page.viewportSize();
      await page.setViewportSize({ width: size.width, height: size.height - heightReduction });
    }
    await expect.poll(async () => {
      const { height, paddingBottom, screenHeight, canvas, backing, hud, footer, overflow, touch, selection, ratio, scroll } = await layout();
      return screenHeight === height && parseFloat(paddingBottom) >= 24
        && hud.bottom <= canvas.top + 1 && canvas.bottom <= footer.top + 1 && footer.bottom <= height - 23
        && canvas.height / height > 0.55 && canvas.height / height < 0.82
        && Math.abs(backing[0] - canvas.width * ratio) < 1.1 && Math.abs(backing[1] - canvas.height * ratio) < 1.1
        && overflow === 'hidden' && touch === 'none' && selection === 'none' && scroll.every(n => n === 0);
    }).toBe(true);
  }
  await expect(page.locator('#hud-tier')).toHaveText('TIER 1');
  await expect(page.locator('#hud-snore-count')).toContainText('0/12');
  await expect(page.locator('#hud-combo')).toHaveText('1x');
  await expect(page.locator('#hud-puppies')).toHaveText('0');
  await expect(page.locator('#hud-shuffles')).toHaveText('1/2');
  await expect(page.locator('#avatar-cupcake')).toHaveAttribute('data-state', 'idle');
  await expect(page.locator('#avatar-teido')).toHaveAttribute('data-state', 'gaming');
  await expect(page.locator('.cupcake-badge')).toHaveCSS('animation-name', 'avatar-sparkle');
  await expect(page.locator('.teido-face')).toHaveCSS('animation-name', 'avatar-blink');
  await expect(page.locator('.teido-controller')).toHaveCSS('background-image', /teido-controller\.svg/);
});

test('two touch taps select with 1.12× scaling, swap, score and briefly cheer for a Big Mac', async ({ page }) => {
  await instrument(page);
  await openGame(page);
  const tiles = findSwap(await frame(page), { preferredKind: 'bigMac' });
  const [a, b] = await canvasPoints(page, tiles);
  await controlAnimationFrames(page);
  await page.touchscreen.tap(a.x, a.y);
  await page.evaluate(() => window.munchiesProbe.advanceFrames(8));
  const selectedScale = await page.evaluate(({ x, y }) =>
    window.munchiesProbe.frame.find(tile => Math.abs(tile.x - x) < 1 && Math.abs(tile.y - y) < 1)?.scale,
  tiles[0]);
  expect(selectedScale).toBeCloseTo(1.12, 2);
  await expect(page.locator('#hud-score')).toHaveText('0');
  await page.touchscreen.tap(b.x, b.y);
  await expect(page.locator('#hud-score')).not.toHaveText('0');
  await expect(page.locator('#hud-tier-pct')).not.toHaveText('0%');
  await expect(page.locator('#hud-best')).not.toHaveText('BEST 0');
  const cupcake = page.locator('#avatar-cupcake');
  await test.step('Observe Cupcake cheer during swap playback', async () => {
    await advanceAnimationUntil(cupcake, 'data-state', 'cheerBigMac');
  });
  await page.evaluate(() => window.munchiesProbe.advanceFrames(20));
  await expect(cupcake).toHaveAttribute('data-state', 'idle');
});

test('drag crosses 35% before release, ignores sub-threshold movement and only spends one move', async ({ page }) => {
  await instrument(page, { sound: true });
  await openGame(page);
  const [a, b] = await canvasPoints(page, findSwap(await frame(page), { axis: 'x' }));
  const cell = b.x - a.x;
  await page.mouse.move(a.x, a.y);
  await page.mouse.down();
  await page.mouse.move(a.x + cell * 0.33, a.y);
  await expect(page.locator('#hud-score')).toHaveText('0');
  expect(await page.evaluate(() => window.munchiesProbe.tones)).toHaveLength(0);
  await page.mouse.move(a.x + cell * 0.37, a.y);
  await expect(page.locator('#hud-score')).not.toHaveText('0');
  await page.mouse.move(b.x + cell, a.y);
  await page.mouse.up();
  const swaps = await page.evaluate(() => window.munchiesProbe.tones.filter(tone => tone.frequency === 310).length);
  expect(swaps).toBe(1);
});

test('invalid tap and cancelled drag preserve score, meter and board', async ({ page }) => {
  await instrument(page, { sound: true });
  await openGame(page);
  const before = await frame(page);
  const [a, b] = await canvasPoints(page, findSwap(before, { valid: false }));
  await page.touchscreen.tap(a.x, a.y);
  await page.touchscreen.tap(b.x, b.y);
  await expect.poll(() => page.evaluate(() => window.munchiesProbe.tones.some(tone => tone.frequency === 210))).toBeTruthy();
  await expect.poll(async () => {
    const after = await frame(page);
    return after.map(row => row.map(tile => tile.kind));
  }).toEqual(before.map(row => row.map(tile => tile.kind)));
  await expect(page.locator('#hud-score')).toHaveText('0');
  await expect(page.locator('#hud-snore-count')).toContainText('0/12');

  const [start, end] = await canvasPoints(page, findSwap(before));
  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  await page.locator('#board-canvas').dispatchEvent('pointercancel', {
    pointerId: 1, clientX: start.x, clientY: start.y,
  });
  await page.mouse.move(end.x, end.y);
  await page.mouse.up();
  await expect(page.locator('#hud-score')).toHaveText('0');
});

test('first pointerdown unlocks WebAudio and cascade notes rise one semitone per wave', async ({ page }) => {
  await instrument(page, { sound: true });
  await page.goto('/');
  expect(await page.evaluate(() => window.munchiesProbe.contexts)).toBe(0);
  const playButton = page.getByRole('button', { name: 'Play Endless Run' });
  await expect(playButton).toBeEnabled();
  const play = await playButton.boundingBox();
  await page.mouse.move(play.x + play.width / 2, play.y + play.height / 2);
  await page.mouse.down();
  await expect.poll(() => page.evaluate(() => window.munchiesProbe.resumes)).toBe(1);
  await expect(page.locator('#screen-home')).toBeVisible();
  await page.mouse.up();
  await frame(page);
  await controlAnimationFrames(page);
  const canvas = page.locator('#board-canvas');
  let tones = [], notes = [];
  for (let turn = 0; turn < 5 && notes.length < 2; turn++) {
    await page.evaluate(() => { window.munchiesProbe.tones = []; });
    const [a, b] = await canvasPoints(page, findSwap(await frame(page), { longest: true }));
    await page.touchscreen.tap(a.x, a.y);
    await page.touchscreen.tap(b.x, b.y);
    await expect(canvas).toHaveAttribute('aria-busy', 'true');
    await advanceAnimationUntil(canvas, 'aria-busy', 'false');
    tones = await page.evaluate(() => window.munchiesProbe.tones);
    notes = tones.filter(tone => tone.gain === 0.22 && Math.abs(tone.stop - tone.start - 0.16) < 0.001);
  }
  expect(notes.length).toBeGreaterThanOrEqual(2);
  expect(notes[0].frequency).toBeCloseTo(523.25);
  for (let i = 1; i < notes.length; i++) {
    expect(notes[i].frequency / notes[i - 1].frequency).toBeCloseTo(2 ** (1 / 12), 8);
  }
  expect(tones.every(tone => tone.stop > tone.start && tone.stop - tone.start < 0.6)).toBeTruthy();
  expect(tones.every(tone => tone.gain > 0 && tone.gain <= 0.3)).toBeTruthy();
  expect(await page.evaluate(() => window.munchiesProbe.contexts)).toBe(1);
});

test('pause settings switch independently and persist across reload', async ({ page }) => {
  await instrument(page, { sound: true });
  await openGame(page);
  await page.getByRole('button', { name: 'Pause' }).tap();
  const settings = page.getByRole('dialog', { name: 'Settings' });
  await expect(settings).toBeVisible();
  const sound = settings.getByRole('checkbox', { name: /Sound Effects/ });
  const snore = settings.getByRole('checkbox', { name: /Goofy Snore Sounds/ });
  const shake = settings.getByRole('checkbox', { name: /Screen Shake/ });
  await sound.uncheck();
  await expect(snore).toBeEnabled();
  await expect(snore).toBeChecked();
  await snore.uncheck();
  await expect(shake).toBeChecked();
  await shake.uncheck();
  await settings.getByRole('button', { name: 'Close settings' }).tap();
  const [a, b] = await canvasPoints(page, findSwap(await frame(page)));
  await page.touchscreen.tap(a.x, a.y);
  await page.touchscreen.tap(b.x, b.y);
  await expect(page.locator('#hud-score')).not.toHaveText('0');
  expect(await page.evaluate(() => window.munchiesProbe.tones)).toHaveLength(0);
  await page.reload();
  await page.getByRole('button', { name: 'Settings', exact: true }).tap();
  for (const control of [sound, snore, shake]) await expect(control).not.toBeChecked();
  await expect(settings.getByText('Restart Run')).toBeHidden();
  await page.mouse.click(4, 4);
  await expect(settings).toBeHidden();
});

test('shuffle is spent once, keeps score, and restart restores the opening HUD', async ({ page }) => {
  await instrument(page);
  await openGame(page);
  const shuffle = page.getByRole('button', { name: /SHUFFLE/ });
  await shuffle.tap();
  await expect(shuffle).toBeDisabled();
  await expect(page.locator('#hud-shuffles')).toHaveText('0/2');
  await expect(page.locator('#hud-score')).toHaveText('0');
  await expect(page.locator('#board-canvas')).toHaveAttribute('aria-busy', 'false');
  findSwap(await frame(page));
  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: /Restart Run/ }).tap();
  await expect(shuffle).toBeEnabled();
  await expect(page.locator('#hud-shuffles')).toHaveText('1/2');
  await expect(page.locator('#hud-score')).toHaveText('0');
});

test('making progress and leaving a run saves cumulative score and earns a Polaroid exactly once', async ({ page }) => {
  await instrument(page, { progress: { ...emptyProgress, cumulativeScore: 9_999 } });
  await openGame(page);
  const [a, b] = await canvasPoints(page, findSwap(await frame(page)));
  await page.touchscreen.tap(a.x, a.y);
  await page.touchscreen.tap(b.x, b.y);
  await expect(page.locator('#hud-score')).not.toHaveText('0');
  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: /Back to Home/ }).tap();
  const progress = await readProgress(page);
  expect(progress.highScore).toBeGreaterThan(0);
  expect(progress.cumulativeScore).toBe(9_999 + progress.highScore);
  await expect(page.locator('#home-scrapbook-count')).toHaveText('1/8');
  await page.reload();
  await expect(page.locator('#home-highscore')).toHaveText(String(progress.highScore));
  await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
  await expect(page.locator('.polaroid-card.is-unlocked')).toHaveText(/Pre-17:00 Korv Dash.*Biltema blue-and-white board trim/);
  expect(await readProgress(page)).toEqual(progress);
});

const milestones = [
  ['cumulativeScore', 10_000, 'Pre-17:00 Korv Dash', 'Biltema blue-and-white board trim'],
  ['totalBigMacsMatched', 100, "Cupcake's Big Mac Run", 'Golden sesame-seed tile border'],
  ['totalTeidoSurgesTriggered', 10, "Teido's Pad Thai & PS5 Night", 'Neon controller-glow backdrop'],
  ['totalFiestaBombsCreated', 15, 'Hermanos Taco Tuesday', 'Warm fiesta sunset backdrop'],
  ['bestCascadeCombo', 5, 'Partille Poke Date', 'Coastal pastel backdrop'],
  ['totalPuppiesRescued', 1, 'First Puppy Adopted', 'Sleeping puppy next to Cupcake'],
  ['totalPuppiesRescued', 25, 'Pack Leader', 'Puppy Paw tile trail effect'],
  ['totalSnoreBubblesPopped', 50, "Survived Teido's Snoring", 'Midnight-blue Light Sleeper theme'],
];

test('scrapbook has eight milestones with exact unlock boundaries and selectable unlocked themes', async ({ page }) => {
  const below = Object.fromEntries(milestones.map(([key, target]) => [key, target - 1]));
  await instrument(page, { progress: { ...emptyProgress, ...below, highScore: 4000, highestTierReached: 8 } });
  await page.goto('/');

  const openScrapbook = async () => {
    await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
    await expect(page.getByRole('dialog', { name: "Couple's Scrapbook" })).toBeVisible();
    await expect(page.locator('.polaroid-card')).toHaveCount(8);
  };
  await openScrapbook();
  await expect(page.locator('#scrapbook-best-tier')).toHaveText('T8');
  for (const [key, target, title, reward] of milestones) {
    await page.evaluate(({ progressKey, key, value }) => {
      const data = JSON.parse(localStorage.getItem(progressKey));
      data[key] = value;
      localStorage.setItem(progressKey, JSON.stringify(data));
    }, { progressKey, key, value: target - 1 });
    await page.reload();
    await openScrapbook();
    const card = page.locator('.polaroid-card').filter({ has: page.getByRole('heading', { name: title, exact: true }) });
    await expect(card).not.toHaveClass(/is-unlocked/);
    await page.evaluate(({ progressKey, key, value }) => {
      const data = JSON.parse(localStorage.getItem(progressKey));
      data[key] = value;
      localStorage.setItem(progressKey, JSON.stringify(data));
    }, { progressKey, key, value: target });
    await page.reload();
    await openScrapbook();
    await expect(card).toHaveClass(/is-unlocked/);
    await expect(card).toContainText(reward);
  }
  await expect(page.locator('#scrapbook-unlocked-count')).toHaveText('8/8');
  const theme = page.getByRole('button', { name: /PS5 Neon Glow/ });
  await theme.tap();
  await expect(page.locator('body')).toHaveAttribute('data-theme', 'neonPS5');
  await page.reload();
  await expect(page.locator('body')).toHaveAttribute('data-theme', 'neonPS5');
  await page.getByRole('button', { name: 'Play Endless Run' }).tap();
  await expect(page.locator('#cupcake-sleeping-puppy')).toBeVisible();
});

test('iOS install tip appears only in a normal Safari tab and remembers dismissal', async ({ page, browserName }) => {
  await page.goto('/');
  const tip = page.getByRole('complementary', { name: 'Install Munchies' });
  if (browserName !== 'webkit') {
    await expect(tip).toBeHidden();
    return;
  }
  await expect(tip).toBeVisible();
  await tip.getByRole('button', { name: 'Dismiss install tip' }).tap();
  await expect(tip).toBeHidden();
  await page.reload();
  await expect(tip).toBeHidden();
  await page.evaluate(() => localStorage.removeItem('munchies.installTipDismissed'));
  await page.addInitScript(() => Object.defineProperty(navigator, 'standalone', { value: true }));
  await page.reload();
  await expect(tip).toBeHidden();
});

test('service worker pre-caches executable, glue and sprites and supports cold offline play', async ({ page, context }) => {
  await instrument(page);
  await page.goto('/manifest.webmanifest');
  await page.evaluate(() => caches.open('unrelated-cache'));
  await page.goto('/');
  await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBeTruthy();
  const cache = await page.evaluate(async () => {
    const names = await caches.keys();
    const files = (await Promise.all(names.filter(name => name.startsWith('munchies-')).map(async name => {
      const store = await caches.open(name);
      return (await store.keys()).map(request => new URL(request.url).pathname);
    }))).flat();
    return { names, files };
  });
  expect(cache.names).toContain('unrelated-cache');
  expect(cache.files).toEqual(expect.arrayContaining([
    '/', '/index.html', '/munchies.wasm', '/bootstrap.js', '/styles.css', '/manifest.webmanifest',
    ...['cupcake', 'teido', 'hermanosTaco', 'partillePoke', 'biltemaCombo', 'bigMac', 'puppy', 'padThai']
      .map(tile => `/assets/tile-${tile}.svg`),
  ]));
  expect(cache.files.some(file => file.startsWith('/runtime/') && /\.(?:m?js)$/.test(file))).toBeTruthy();

  await context.setOffline(true);
  const offlinePage = await context.newPage();
  await instrument(offlinePage);
  await openGame(offlinePage);
  const [a, b] = await canvasPoints(offlinePage, findSwap(await frame(offlinePage)));
  await offlinePage.touchscreen.tap(a.x, a.y);
  await offlinePage.touchscreen.tap(b.x, b.y);
  await expect(offlinePage.locator('#hud-score')).not.toHaveText('0');
});
