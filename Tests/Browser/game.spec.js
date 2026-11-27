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

async function instrument(page, { sound = false, progress, gameSeed, snackRuns = false } = {}) {
  await page.addInitScript(({ sound, progress, progressKey, gameSeed, snackRuns }) => {
    if (progress && localStorage.getItem(progressKey) === null) {
      localStorage.setItem(progressKey, JSON.stringify(progress));
    }

    // Drive the same opening board across browsers through WASI's normal random source.
    let rng = 341856;
    crypto.getRandomValues = bytes => {
      if (gameSeed !== undefined) {
        bytes.fill(0);
        for (let i = 0; i < bytes.length; i += 8) bytes[i] = gameSeed;
        return bytes;
      }
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
    const probe = Object.assign(window.munchiesProbe ??= {}, {
      frame: [], contexts: 0, resumes: 0, tones: [], audioTime: 0, musicBuffers: 0, musicStarts: [], musicStops: 0,
      rasterizedSprites: new Set(), receipts: 0,
    });
    const canvas = CanvasRenderingContext2D.prototype;
    const clear = canvas.clearRect;
    canvas.clearRect = function (...args) {
      if (this.canvas.id === 'board-canvas') {
        probe.frame = [];
        probe.receipts = 0;
      }
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
            locked: this.globalAlpha < 0.9,
            rasterized: source instanceof HTMLCanvasElement || source instanceof ImageBitmap,
          });
        } else {
          sprites.set(this.canvas, kind);
          probe.rasterizedSprites.add(kind);
        }
      }
      return draw.call(this, source, ...args);
    };
    const fillText = canvas.fillText;
    canvas.fillText = function (text, ...args) {
      if (this.canvas.id === 'board-canvas') {
        const tile = probe.frame.at(-1);
        if (tile && text === '🍦') tile.wild = true;
        if (tile && snackRuns && ['↔', '↕', '✦'].includes(text)) tile.special = text;
      }
      return fillText.call(this, text, ...args);
    };

    if (snackRuns) {
      const fill = canvas.fill;
      canvas.fill = function (...args) {
        if (this.canvas.id === 'board-canvas' && this.fillStyle === '#fff2bf') probe.receipts++;
        return fill.apply(this, args);
      };
    }

    if (sound) {
      window.AudioContext = class {
        constructor() { probe.contexts++; }
        get currentTime() { return probe.audioTime; }
        state = 'suspended';
        destination = {};
        resume() { this.state = 'running'; probe.resumes++; return Promise.resolve(); }
        createBuffer(channels, length, sampleRate) {
          const samples = new Float32Array(length);
          probe.musicBuffers++;
          return { duration: length / sampleRate, getChannelData: () => samples };
        }
        createBufferSource() {
          return {
            connect(volume) { this.volume = volume; },
            disconnect() {},
            start(when, offset) {
              probe.musicStarts.push({ loop: this.loop, duration: this.buffer.duration, offset, gain: this.volume.peakGain,
                audible: this.buffer.getChannelData(0).some(sample => Math.abs(sample) > 0.01) });
            },
            stop() { probe.musicStops++; },
          };
        }
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
          const node = { peakGain: 0, connect() {}, disconnect() {} };
          node.gain = {
            value: 0,
            cancelScheduledValues() {},
            setValueAtTime() {},
            linearRampToValueAtTime: gain => { node.peakGain = gain; },
            exponentialRampToValueAtTime() {},
          };
          return node;
        }
      };
    }
  }, { sound, progress, progressKey, gameSeed, snackRuns });
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
  const kinds = board.map(row => row.map(tile => tile.locked || tile.wild ? null : tile.kind));
  const partners = axis === 'x' ? [[0, 1]] : axis === 'y' ? [[1, 0]] : [[0, 1], [1, 0]];
  let best, bestSize = 0;
  for (let r = 0; r < 9; r++) {
    for (let c = 0; c < 8; c++) {
      for (const [dr, dc] of partners) {
        if (r + dr >= 9 || c + dc >= 8) continue;
        if (board[r][c].locked || board[r + dr][c + dc].locked) continue;
        const after = kinds.map(row => row.slice());
        [after[r][c], after[r + dr][c + dc]] = [after[r + dr][c + dc], after[r][c]];
        const matches = [];
        for (const [row, col] of [[r, c], [r + dr, c + dc]]) {
          const kind = after[row][col];
          if (kind === null || kind === 'puppy' || kind === 'padThai') continue;
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

async function openTitleScreen(page, { manualFrames = false } = {}) {
  if (manualFrames) await controlAnimationFrames(page, { fromStartup: true });
  await page.goto('/');
  if (manualFrames) {
    await expect.poll(() => page.evaluate(() => window.munchiesProbe.rasterizedSprites.size), {
      message: 'All tile sprites are rasterized before starting the run',
    }).toBe(8);
  }
}

async function openGame(page, options = {}) {
  await openTitleScreen(page, options);
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

async function controlAnimationFrames(page, { fromStartup = false } = {}) {
  const install = () => {
    const pending = new Map();
    let requestId = 0;
    let frameTime = performance.now();
    window.requestAnimationFrame = callback => {
      pending.set(++requestId, callback);
      return requestId;
    };
    window.cancelAnimationFrame = id => pending.delete(id);
    const probe = window.munchiesProbe ??= {};
    probe.hasPendingFrame = () => pending.size > 0;
    probe.advanceFrames = count => {
      for (let i = 0; i < count; i++) {
        // Use the renderer's largest supported frame delta.
        frameTime += 50;
        const callbacks = [...pending.values()];
        pending.clear();
        for (const callback of callbacks) callback(frameTime);
      }
    };
  };
  if (fromStartup) {
    await page.addInitScript(install);
    return;
  }
  await page.evaluate(install);
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

async function tapSwap(page, positions) {
  const board = await frame(page);
  const [a, b] = await canvasPoints(page, positions.map(([row, col]) => board[row][col]));
  await page.touchscreen.tap(a.x, a.y);
  await page.touchscreen.tap(b.x, b.y);
}

async function playTurn(page, positions) {
  const canvas = page.locator('#board-canvas');
  await tapSwap(page, positions);
  await expect(canvas).toHaveAttribute('aria-busy', 'true');
  await advanceAnimationUntil(canvas, 'aria-busy', 'false');
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
  const cellBackgrounds = await page.evaluate(tiles => {
    const ctx = document.querySelector('#board-canvas').getContext('2d');
    const cell = tiles[0][1].x - tiles[0][0].x;
    return tiles.flat().map(({ x, y }) => {
      const sx = Math.round((x - cell * 0.44) * devicePixelRatio);
      const sy = Math.round((y - cell * 0.44) * devicePixelRatio);
      return Array.from(ctx.getImageData(sx, sy, 1, 1).data).join(',');
    });
  }, board);
  expect(new Set(cellBackgrounds)).toEqual(new Set(['32,30,46,255']));
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
    const story = document.querySelector('#run-focus');
    const cs = getComputedStyle(document.body);
    return {
      height: innerHeight,
      paddingBottom: getComputedStyle(document.querySelector('#screen-game')).paddingBottom,
      screenHeight: document.querySelector('#screen-game').getBoundingClientRect().height,
      canvas: canvas.getBoundingClientRect().toJSON(), backing: [canvas.width, canvas.height],
      hud: document.querySelector('.hud-header').getBoundingClientRect().toJSON(),
      story: story.getBoundingClientRect().toJSON(),
      footer: document.querySelector('.thumb-dock').getBoundingClientRect().toJSON(),
      overflow: cs.overflow, boardTouch: getComputedStyle(canvas).touchAction, selection: cs.userSelect,
      ratio: devicePixelRatio, scroll: [scrollX, scrollY],
    };
  });
  for (const heightReduction of [0, 140]) {
    if (heightReduction) {
      const size = page.viewportSize();
      await page.setViewportSize({ width: size.width, height: size.height - heightReduction });
    }
    await expect.poll(async () => {
      const { height, paddingBottom, screenHeight, canvas, backing, hud, story, footer, overflow, boardTouch, selection, ratio, scroll } = await layout();
      const cellSize = Math.floor(Math.min((canvas.width - 20) / 8, (canvas.height - 20) / 9));
      return screenHeight === height && parseFloat(paddingBottom) >= 24
        && hud.bottom <= story.top + 1 && story.bottom <= canvas.top + 1
        && canvas.bottom <= footer.top + 1 && footer.bottom <= height - 23
        && cellSize >= (heightReduction ? 32 : 42)
        && Math.abs(backing[0] - canvas.width * ratio) < 1.1 && Math.abs(backing[1] - canvas.height * ratio) < 1.1
        && overflow === 'hidden' && boardTouch === 'none'
        && selection === 'none' && scroll.every(n => n === 0);
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
  const tiles = await test.step('Draw the opening board and find a Big Mac swap', async () => {
    await openGame(page, { manualFrames: true });
    return findSwap(await frame(page), { preferredKind: 'bigMac' });
  });
  const [a, b] = await canvasPoints(page, tiles);
  await test.step('Select and animate the first tile', async () => {
    await page.touchscreen.tap(a.x, a.y);
    await page.evaluate(() => window.munchiesProbe.advanceFrames(8));
    const selectedScale = await page.evaluate(({ x, y }) =>
      window.munchiesProbe.frame.find(tile => Math.abs(tile.x - x) < 1 && Math.abs(tile.y - y) < 1)?.scale,
    tiles[0]);
    expect(selectedScale).toBeCloseTo(1.12, 2);
    await expect(page.locator('#hud-score')).toHaveText('0');
  });
  await test.step('Play the Big Mac swap and observe Cupcake cheer', async () => {
    await page.touchscreen.tap(b.x, b.y);
    await expect(page.locator('#hud-score')).not.toHaveText('0');
    await expect(page.locator('#hud-tier-pct')).not.toHaveText('0%');
    await expect(page.locator('#hud-best')).not.toHaveText('BEST 0');
    const cupcake = page.locator('#avatar-cupcake');
    await advanceAnimationUntil(cupcake, 'data-state', 'cheerBigMac');
    await page.evaluate(() => window.munchiesProbe.advanceFrames(20));
    await expect(cupcake).toHaveAttribute('data-state', 'idle');
  });
});

test('earned Big Mac reward colors a match burst while tile outlines follow selection', async ({ page }) => {
  await instrument(page, {
    progress: { ...emptyProgress, cumulativeScore: 10_000, totalBigMacsMatched: 100 },
  });
  await page.addInitScript(() => {
    const paint = window.munchiesPaint = { strokeWidths: [], fills: [] };
    const ctx = CanvasRenderingContext2D.prototype;
    const { clearRect, stroke, fill } = ctx;
    ctx.clearRect = function (...args) {
      if (this.canvas.id === 'board-canvas') {
        paint.strokeWidths = [];
        paint.fills = [];
      }
      return clearRect.apply(this, args);
    };
    ctx.stroke = function (...args) {
      if (this.canvas.id === 'board-canvas') paint.strokeWidths.push(this.lineWidth);
      return stroke.apply(this, args);
    };
    ctx.fill = function (...args) {
      if (this.canvas.id === 'board-canvas') paint.fills.push(this.fillStyle);
      return fill.apply(this, args);
    };
  });
  await openGame(page, { manualFrames: true });
  const [a, b] = await canvasPoints(page, findSwap(await frame(page), { preferredKind: 'bigMac' }));
  const strokes = () => page.evaluate(() => window.munchiesPaint.strokeWidths);
  const golden = '#f7cc73';
  // The Biltema frame and the grid are the two strokes on the idle opening board.
  expect(await strokes()).toEqual([3.5, 1]);
  await page.touchscreen.tap(a.x, a.y);
  await page.evaluate(() => window.munchiesProbe.advanceFrames(8));
  const selectedStrokes = await strokes();
  expect(selectedStrokes).toHaveLength(3);
  expect(selectedStrokes.at(-1)).toBeCloseTo(2.4);

  await page.touchscreen.tap(b.x, b.y);
  const canvas = page.locator('#board-canvas');
  await expect(canvas).toHaveAttribute('aria-busy', 'true');
  const sawGold = await canvas.evaluate((element, color) => {
    for (let frame = 0; frame < 200 && element.getAttribute('aria-busy') === 'true'; frame++) {
      window.munchiesProbe.advanceFrames(1);
      if (window.munchiesPaint.fills.includes(color)) return true;
    }
    return false;
  }, golden);
  expect(sawGold).toBe(true);
  await advanceAnimationUntil(canvas, 'aria-busy', 'false');
  await page.evaluate(() => window.munchiesProbe.advanceFrames(12));
  expect(await page.evaluate(color => window.munchiesPaint.fills.includes(color), golden)).toBe(false);
  expect((await strokes()).some(width => Math.abs(width - 2.4) < 0.001)).toBe(false);
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
  const canvas = page.locator('#board-canvas');
  const before = await test.step('Paint the opening board with the animation clock held', async () => {
    await openGame(page, { manualFrames: true });
    return frame(page);
  });
  const kinds = board => board.map(row => row.map(tile => tile.kind));
  const checkUnchanged = async () => {
    expect(kinds(await frame(page))).toEqual(kinds(before));
    await expect(page.locator('#hud-score')).toHaveText('0');
    await expect(page.locator('#hud-tier-pct')).toHaveText('0%');
    await expect(page.locator('#hud-snore-count')).toContainText('0/12');
  };

  await test.step('Finish an invalid swap before starting the drag', async () => {
    const [a, b] = await canvasPoints(page, findSwap(before, { valid: false }));
    await page.touchscreen.tap(a.x, a.y);
    await page.touchscreen.tap(b.x, b.y);
    await expect(canvas).toHaveAttribute('aria-busy', 'true');
    await advanceAnimationUntil(canvas, 'aria-busy', 'false');
    expect(await page.evaluate(() => window.munchiesProbe.tones.map(tone => tone.frequency))).toEqual([210]);
    await checkUnchanged();
  });

  await test.step('Cancel the captured pointer before it crosses into a legal swap', async () => {
    const [start, end] = await canvasPoints(page, findSwap(before));
    await canvas.evaluate(element => {
      element.addEventListener('pointerdown', event => {
        window.munchiesProbe.dragPointerId = event.pointerId;
      }, { once: true });
    });
    await page.mouse.move(start.x, start.y);
    await page.mouse.down();
    const pointerId = await page.evaluate(() => window.munchiesProbe.dragPointerId);
    expect(pointerId).toEqual(expect.any(Number));
    expect(await canvas.evaluate((element, id) => element.hasPointerCapture(id), pointerId)).toBe(true);
    await page.mouse.move(start.x + (end.x - start.x) * 0.2, start.y + (end.y - start.y) * 0.2);
    await canvas.dispatchEvent('pointercancel', { pointerId });
    await page.mouse.move(end.x, end.y);
    await page.mouse.up();
    await expect(canvas).toHaveAttribute('aria-busy', 'false');
    await page.evaluate(() => window.munchiesProbe.advanceFrames(8));
    expect(await page.evaluate(() => window.munchiesProbe.tones.map(tone => tone.frequency))).toEqual([210]);
    await checkUnchanged();
  });
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

test('background music loops in a run, pauses with the game, and has an independent saved toggle', async ({ page }) => {
  await instrument(page, { sound: true, progress: emptyProgress });
  await page.goto('/');
  const play = page.getByRole('button', { name: 'Play Endless Run' });
  await expect(play).toBeEnabled();
  const musicStarts = () => page.evaluate(() => window.munchiesProbe.musicStarts);
  const musicStops = () => page.evaluate(() => window.munchiesProbe.musicStops);
  expect(await musicStarts()).toHaveLength(0);
  await play.tap();
  await expect.poll(async () => (await musicStarts()).length).toBe(1);
  const loop = (await musicStarts())[0];
  expect(loop).toMatchObject({ loop: true, offset: 0, audible: true });
  expect(loop.duration).toBeGreaterThan(60);
  expect(loop.gain).toBeLessThan(0.12);

  await page.evaluate(() => { window.munchiesProbe.audioTime = 5; });
  const pause = page.getByRole('button', { name: 'Pause' });
  const settings = page.getByRole('dialog', { name: 'Settings' });
  await pause.tap();
  await expect.poll(musicStops).toBe(1);
  const music = settings.getByRole('checkbox', { name: /Background Music/ });
  const sound = settings.getByRole('checkbox', { name: /Sound Effects/ });
  const snore = settings.getByRole('checkbox', { name: /Goofy Snore Sounds/ });
  await expect(music).toBeChecked();
  await sound.uncheck();
  await expect(music).toBeChecked();
  await settings.getByRole('button', { name: 'Close settings' }).tap();
  await expect.poll(async () => (await musicStarts()).length).toBe(2);
  expect((await musicStarts())[1].offset).toBeCloseTo(5);

  for (const hidden of [true, false]) {
    await page.evaluate(value => {
      Object.defineProperty(document, 'hidden', { value, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    }, hidden);
    if (hidden) await expect.poll(musicStops).toBe(2);
    else await expect.poll(async () => (await musicStarts()).length).toBe(3);
  }
  expect(await page.evaluate(() => window.munchiesProbe.musicBuffers)).toBe(1);

  await pause.tap();
  await expect.poll(musicStops).toBe(3);
  await sound.check();
  await music.uncheck();
  await expect(sound).toBeChecked();
  await expect(snore).toBeChecked();
  await settings.getByRole('button', { name: 'Close settings' }).tap();
  const [a, b] = await canvasPoints(page, findSwap(await frame(page)));
  await page.touchscreen.tap(a.x, a.y);
  await page.touchscreen.tap(b.x, b.y);
  await expect(page.locator('#hud-score')).not.toHaveText('0');
  expect(await page.evaluate(() => window.munchiesProbe.tones.length)).toBeGreaterThan(0);
  expect(await musicStarts()).toHaveLength(3);
  expect((await readProgress(page)).backgroundMusicEnabled).toBe(false);

  await page.reload();
  await play.tap();
  await pause.tap();
  await expect(music).not.toBeChecked();
  expect(await musicStarts()).toHaveLength(0);
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

test('run moments stay pinned above the board and keep other stories in a journal', async ({ page }) => {
  // Seed 2 produces a puppy on the first swap and a Tier 2 Korv Dash on the second.
  await page.setViewportSize({ width: 320, height: 600 });
  await page.clock.install({ time: 0 });
  await instrument(page, { gameSeed: 2 });
  await openGame(page, { manualFrames: true });

  const story = page.getByRole('region', { name: 'Run story' });
  const moment = story.getByRole('status');
  const journalButton = story.getByRole('button', { name: 'Journal' });
  await expect(journalButton).toBeVisible();
  await expect(moment).toBeEmpty();

  await playTurn(page, [[7, 4], [8, 4]]);
  await expect(moment).toHaveText('Stray puppy spotted');
  expect(await moment.locator('.event-title').evaluate(title => {
    const card = title.closest('.event-card').getBoundingClientRect();
    const text = title.getBoundingClientRect();
    return text.top >= card.top && text.bottom <= card.bottom;
  })).toBeTruthy();
  expect(await page.locator('.thumb-dock').evaluate(dock => dock.scrollWidth <= dock.clientWidth)).toBeTruthy();
  await expect(moment.locator('.event-travel')).toHaveCSS('animation-name', 'event-walk-in');
  await expect(moment.locator('.event-sprite')).toHaveCSS('animation-name', 'event-puppy-gait');
  await playTurn(page, [[2, 0], [3, 0]]);
  await expect(moment).toContainText('Stray puppy spotted');
  await page.clock.fastForward(60_000);
  await expect(moment).toContainText('Stray puppy spotted');

  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(moment.locator('.event-travel')).toHaveCSS('animation-name', 'none');
  const canvas = page.locator('#board-canvas');
  await tapSwap(page, [[5, 3], [6, 3]]);
  await expect(canvas).toHaveAttribute('aria-busy', 'true');
  await journalButton.tap();
  const journal = page.getByRole('dialog', { name: 'Run Journal' });
  const trip = journal.getByRole('listitem').filter({ hasText: 'Pre-17:00 Korv Dash!' });
  await expect(trip).toBeVisible();
  await expect(trip.locator('.event-art')).toHaveCSS('background-image', /event-biltema-store\.svg/);
  await expect(journal.getByText('Guide it to the bottom row.')).toBeVisible();
  await page.evaluate(() => window.munchiesProbe.advanceFrames(120));
  await expect(canvas).toHaveAttribute('aria-busy', 'true');
  await journal.evaluate(dialog => {
    window.munchiesProbe.journalClosed = false;
    dialog.addEventListener('close', () => { window.munchiesProbe.journalClosed = true; }, { once: true });
  });
  await journal.getByRole('button', { name: 'Close journal' }).tap();
  await expect(journal).toBeHidden();
  await expect.poll(() => page.evaluate(() => window.munchiesProbe.journalClosed)).toBe(true);
  await advanceAnimationUntil(canvas, 'aria-busy', 'false');
  await expect(moment).toContainText('Stray puppy spotted');

  for (const swap of [
    [[7, 3], [8, 3]], [[0, 1], [1, 1]], [[0, 1], [0, 2]], [[1, 2], [2, 2]], [[2, 2], [2, 3]], [[1, 2], [2, 2]],
  ]) {
    await playTurn(page, swap);
    await expect(moment).toContainText('Stray puppy spotted');
  }
  // A later surge gets the focus. The older Biltema story stays in the journal.
  await playTurn(page, [[2, 0], [2, 1]]);
  await expect(page.locator('#run-moment')).toContainText("Cupcake's Big Mac & Puppy Surge!");

  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: /Restart Run/ }).tap();
  await expect(moment).toBeEmpty();
  await journalButton.tap();
  await expect(journal.getByText('No moments yet.')).toBeVisible();
});

test('Cupcake and PS5 scenes follow their triggers once per run, with the couch returning for the surge', async ({ page }) => {
  await instrument(page, { gameSeed: 6 });
  await openGame(page, { manualFrames: true });

  const cards = page.locator('#run-journal li');
  const schedule = cards.filter({ hasText: "Cupcake's 60% Rule" });
  const gemini = cards.filter({ hasText: 'Gemini Mode' });
  const couch = cards.filter({ hasText: 'PS5 Couch Mode' });

  // Cupcakes and Big Macs matched on separate turns do not qualify for Gemini Mode.
  const opening = [
    [[1, 4], [2, 4]], [[7, 0], [7, 1]], [[5, 2], [6, 2]], [[7, 3], [7, 4]], [[5, 5], [5, 6]],
  ];
  for (const positions of opening.slice(0, 2)) await playTurn(page, positions);
  await expect(schedule).toHaveCount(0);
  await expect(gemini).toHaveCount(0);
  await expect(couch).toHaveCount(0);

  // The third turn matches both snacks and reaches exactly 27 of 45 tiles in a 3× cascade.
  await playTurn(page, opening[2]);
  await expect(page.locator('#hud-tier-pct')).toHaveText('60%');
  await expect(schedule).toContainText('60% work · 60% study');
  await expect(gemini).toContainText('Cupcake + Big Mac in one turn.');
  await expect(couch).toHaveCount(0);

  await playTurn(page, opening[3]);
  await expect(couch).toContainText('4× cascade');
  // Another 4× turn matches both snacks again, while the first milestone cards stay in history.
  await playTurn(page, opening[4]);
  await expect(schedule).toHaveCount(1);
  await expect(gemini).toHaveCount(1);
  await expect(couch).toHaveCount(1);

  await expect(schedule.locator('.event-sprite')).toHaveCSS('background-image', /event-cupcake-schedule\.svg/);
  await expect(gemini.locator('.event-sprite')).toHaveCSS('background-image', /tile-cupcake\.svg.*tile-bigMac\.svg/);
  await expect(couch.locator('.event-sprite')).toHaveCSS('background-image', /event-ps5-couch\.svg/);

  // Continue the same run to Teido's regular tier-six surge and its existing 3× rocket reward.
  for (const positions of [
    [[4, 6], [4, 7]], [[7, 2], [8, 2]], [[2, 3], [2, 4]], [[3, 6], [4, 6]], [[3, 5], [4, 5]],
    [[6, 5], [6, 6]], [[5, 2], [5, 3]], [[3, 6], [3, 7]], [[1, 6], [2, 6]], [[3, 5], [3, 6]],
    [[5, 3], [6, 3]],
  ]) await playTurn(page, positions);
  await expect(page.locator('#hud-tier')).toHaveText('TIER 6');
  await expect(cards.filter({ hasText: "Teido's Pad Thai & PS5 Surge!" })).toHaveAttribute('data-art', 'couch');
  await playTurn(page, [[7, 2], [8, 2]]);
  await expect(cards.filter({ hasText: 'Combo achievement!' })).toContainText('Teido added a Korv Rocket.');

  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: /Restart Run/ }).tap();
  await expect(cards).toHaveCount(0);
  for (const positions of opening.slice(0, 4)) await playTurn(page, positions);
  await expect(schedule).toHaveCount(1);
  await expect(gemini).toHaveCount(1);
  await expect(couch).toHaveCount(1);
});

const snackRunOpening = [
  [[4, 0], [4, 1]], [[0, 5], [0, 6]], [[1, 4], [1, 5]], [[2, 3], [2, 4]], [[3, 4], [4, 4]],
  [[3, 3], [3, 4]], [[4, 4], [5, 4]], [[5, 1], [5, 2]], [[0, 0], [0, 1]], [[2, 0], [2, 1]],
];

async function playToSnackRunOffer(page) {
  const canvas = page.locator('#board-canvas');
  const panel = page.getByRole('region', { name: 'Snack Runs' });
  const events = page.getByRole('region', { name: 'Run story' });
  for (const positions of snackRunOpening.slice(0, 9)) {
    await playTurn(page, positions);
    await expect(panel).toBeHidden();
  }
  const bounds = await canvas.boundingBox();
  await playTurn(page, snackRunOpening[9]);
  await expect(panel).toBeVisible();
  await expect(events).toBeHidden();
  await expect(panel.getByRole('button', { name: 'Biltema Dash' })).toBeVisible();
  await expect(panel.getByRole('button', { name: 'Partille Poke Order' })).toBeVisible();
  const offeredBounds = await canvas.boundingBox();
  for (const edge of ['x', 'y', 'width', 'height']) expect(offeredBounds[edge]).toBeCloseTo(bounds[edge], 0);
  return { canvas, panel, events };
}

async function openSnackRunOffer(page) {
  await instrument(page, { gameSeed: 42, snackRuns: true });
  await openGame(page, { manualFrames: true });
  return playToSnackRunOffer(page);
}

for (const run of [
  {
    title: 'Biltema Dash', opening: 'Clear 3 marked receipts', advanced: 'Clear 2 marked receipts',
    first: [[1, 2], [2, 2]], second: [[0, 3], [1, 3]],
    reward: 'Korv Rocket', art: 'biltema', at: [0, 1], icon: '↔', receipts: [3, 2],
  },
  {
    title: 'Partille Poke Order', opening: 'Match Taco, then Poke', advanced: 'Taco ✓ · Match Poke',
    first: [[1, 3], [2, 3]], second: [[0, 0], [0, 1]],
    reward: 'Fiesta Bomb', art: 'poke', at: [2, 0], icon: '✦', receipts: [0, 0],
  },
]) {
  test(`${run.title} tracks a real board objective and adds its reward`, async ({ page }) => {
    const { canvas, panel, events } = await openSnackRunOffer(page);
    const score = page.locator('#hud-score');
    const offerScore = await score.textContent();
    const receiptCount = () => page.evaluate(() => window.munchiesProbe.receipts);
    await panel.getByRole('button', { name: run.title }).tap();
    const progress = panel.getByRole('status');
    await expect(progress).toContainText(run.opening);
    await expect(progress).toContainText('6 swaps left');
    await expect(progress).toContainText(`Earn a ${run.reward}`);
    await expect(score).toHaveText(offerScore);
    expect(await receiptCount()).toBe(run.receipts[0]);

    await playTurn(page, run.first);
    await expect(progress).toContainText(run.advanced);
    await expect(progress).toContainText('5 swaps left');
    expect(await receiptCount()).toBe(run.receipts[1]);

    await playTurn(page, run.second);
    await expect(panel).toBeHidden();
    await expect(events).toBeVisible();
    const result = events.locator('.event-card');
    await expect(result).toContainText(`${run.title} complete!`);
    await expect(result).toContainText(`${run.reward} earned`);
    await expect(result).toHaveAttribute('data-art', run.art);
    const [row, col] = run.at;
    expect((await frame(page))[row][col].special).toBe(run.icon);
    expect(await receiptCount()).toBe(0);
    await expect(canvas).not.toHaveAttribute('aria-description', /Biltema receipts/);
  });
}

test('ignoring a Snack Run offer lets the next board swap play normally', async ({ page }) => {
  const { panel, events } = await openSnackRunOffer(page);
  await expect(panel.getByRole('button', { name: 'Skip', exact: true })).toBeVisible();
  const previousScore = Number(await page.locator('#hud-score').textContent());
  await playTurn(page, [[1, 2], [2, 2]]);
  await expect(panel).toBeHidden();
  await expect(events).toBeVisible();
  expect(Number(await page.locator('#hud-score').textContent())).toBeGreaterThan(previousScore);
  await expect(events.getByText('Biltema Dash complete!')).toHaveCount(0);
});

test('Snack Runs fit a compact screen and can be skipped or left', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 600 });
  const { panel, events } = await openSnackRunOffer(page);
  const buttons = panel.getByRole('button');
  const fits = await buttons.evaluateAll(elements => elements.every(button => {
    const rect = button.getBoundingClientRect();
    return rect.height >= 44 && rect.width >= 44 && Array.from(button.children).every(child => {
      const text = child.getBoundingClientRect();
      return text.left >= rect.left && text.right <= rect.right && text.top >= rect.top && text.bottom <= rect.bottom;
    });
  }));
  expect(fits).toBeTruthy();

  const score = page.locator('#hud-score');
  const beforeSkip = await score.textContent();
  await panel.getByRole('button', { name: 'Skip', exact: true }).tap();
  await expect(panel).toBeHidden();
  await expect(events).toBeVisible();
  await expect(score).toHaveText(beforeSkip);

  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: /Restart Run/ }).tap();
  await playToSnackRunOffer(page);
  await panel.getByRole('button', { name: 'Biltema Dash' }).tap();
  await expect(panel.getByRole('status')).toContainText('6 swaps left');
  expect(await page.evaluate(() => window.munchiesProbe.receipts)).toBe(3);

  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: 'Close settings' }).tap();
  await expect(panel.getByRole('status')).toContainText('6 swaps left');
  await panel.getByRole('button', { name: 'Leave', exact: true }).tap();
  await expect(panel).toBeHidden();
  await expect(events).toBeVisible();
  await expect(score).toHaveText(beforeSkip);
  expect(await page.evaluate(() => window.munchiesProbe.receipts)).toBe(0);
});

test('clearing mission goals unlocks the route, and retries use the same board', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 600 });
  await instrument(page, { progress: { ...emptyProgress, highScore: 4_321, totalPuppiesRescued: 3 } });
  await openTitleScreen(page, { manualFrames: true });

  const start = page.getByRole('button', { name: 'Play Missions' });
  const menu = page.getByRole('dialog', { name: 'Missions', exact: true });
  const objective = page.getByRole('region', { name: 'Mission objective' });
  const result = page.locator('#dialog-mission-result');
  const next = result.getByRole('button', { name: 'Next mission' });
  await start.tap();
  await expect(menu.getByRole('button', { name: 'Biltema Delivery' })).toBeDisabled();
  await expect(menu.getByRole('button', { name: 'Couch Co-op' })).toBeDisabled();
  await menu.getByRole('button', { name: 'Puppy Pickup' }).tap();
  await expect(objective).toContainText('Guide both puppies to the bottom row.');
  await expect(objective).toContainText('5 swaps left');
  const opening = (await frame(page)).flat().map(tile => tile.kind);
  expect(opening.filter(kind => kind === 'puppy')).toHaveLength(2);
  await expect(page.getByRole('region', { name: 'Run story' })).toBeHidden();
  const objectiveBox = await objective.boundingBox();
  const boardBox = await page.locator('#board-canvas').boundingBox();
  expect(objectiveBox.y + objectiveBox.height).toBeLessThanOrEqual(boardBox.y);

  // Five high-scoring swaps without the second puppy do not unlock the next board.
  for (const swap of [
    [[4, 0], [4, 1]], [[1, 4], [1, 5]], [[2, 3], [2, 4]], [[7, 3], [8, 3]], [[7, 2], [8, 2]],
  ]) await playTurn(page, swap);
  await expect(result).toContainText('Out of swaps');
  await expect(next).toBeHidden();
  expect((await readProgress(page)).highestMissionCleared).toBeUndefined();

  await result.getByRole('button', { name: 'Retry mission' }).tap();
  await expect(objective).toContainText('5 swaps left');
  expect((await frame(page)).flat().map(tile => tile.kind)).toEqual(opening);
  for (const swap of [
    [[6, 0], [7, 0]], [[3, 5], [3, 6]], [[5, 0], [5, 1]], [[7, 1], [8, 1]],
  ]) await playTurn(page, swap);
  await expect(result).toContainText('Puppy Pickup in 4 swaps.');
  expect((await readProgress(page)).highestMissionCleared).toBe(1);

  await next.tap();
  await expect(objective).toContainText('Biltema Delivery');
  await expect(objective).toContainText('6 swaps left');
  await expect(page.locator('#board-canvas')).toHaveAttribute('aria-description', 'Biltema counter. Row 5, column 8.');
  for (const swap of [[[7, 5], [7, 6]], [[1, 5], [2, 5]], [[8, 6], [8, 7]]]) await playTurn(page, swap);
  await expect(result).toContainText('Biltema Delivery in 3 swaps.');

  await next.tap();
  await expect(objective).toContainText('Couch Co-op');
  await expect(objective).toContainText('7 swaps left');
  await expect(page.locator('#board-canvas')).not.toHaveAttribute('aria-description', /Biltema counter/);
  for (const swap of [
    [[7, 1], [7, 2]], [[5, 2], [6, 2]], [[4, 2], [5, 2]], [[4, 2], [4, 3]],
  ]) await playTurn(page, swap);
  await expect(result).toContainText('All missions cleared!');
  await expect(next).toBeHidden();
  const progress = await readProgress(page);
  expect(progress).toMatchObject({ highestMissionCleared: 3, highScore: 4_321, totalPuppiesRescued: 3 });

  await result.getByRole('button', { name: 'Missions', exact: true }).tap();
  await expect(menu.getByText('Cleared', { exact: true })).toHaveCount(3);
  await page.reload();
  await start.tap();
  await expect(menu.getByText('Cleared', { exact: true })).toHaveCount(3);
  await menu.getByRole('button', { name: 'Close missions' }).tap();
  await page.getByRole('button', { name: 'Play Endless Run' }).tap();
  await expect(page.getByRole('region', { name: 'Run story' })).toBeVisible();
  await expect(objective).toBeHidden();
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
  await expect(page.locator('#home-scrapbook-count')).toHaveText('1 tier');
  await page.reload();
  await expect(page.locator('#home-highscore')).toHaveText(String(progress.highScore));
  await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
  await expect(page.locator('.polaroid-card.is-unlocked')).toHaveText(/Pre-17:00 Korv Dash.*Biltema blue-and-white board trim/);
  expect(await readProgress(page)).toEqual(progress);
});

const milestones = [
  ['cumulativeScore', 10_000, 'Pre-17:00 Korv Dash', 'Biltema blue-and-white board trim'],
  ['totalBigMacsMatched', 100, "Cupcake's Big Mac Run", 'Golden sparkles on Big Mac matches'],
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
  await expect(page.locator('#scrapbook-unlocked-count')).toHaveText('13');
  const theme = page.getByRole('button', { name: /PS5 Neon Glow/ });
  await theme.tap();
  await expect(page.locator('body')).toHaveAttribute('data-theme', 'neonPS5');
  await page.reload();
  await expect(page.locator('body')).toHaveAttribute('data-theme', 'neonPS5');
  await page.getByRole('button', { name: 'Play Endless Run' }).tap();
  await expect(page.locator('#cupcake-sleeping-puppy')).toBeVisible();
});

test('scrapbook keeps the next goal visible on every card after very long play', async ({ page }) => {
  await instrument(page, { progress: {
    ...emptyProgress,
    cumulativeScore: 50_000_500_000_000,
    totalPuppiesRescued: 25,
    totalBigMacsMatched: 300,
    totalTeidoSurgesTriggered: 30,
    totalFiestaBombsCreated: 45,
    bestCascadeCombo: 6,
    totalFivePlusCascades: 3,
    totalSnoreBubblesPopped: 150,
  } });
  await page.goto('/');
  await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
  const album = page.getByRole('dialog', { name: "Couple's Scrapbook" });
  const cards = album.getByRole('article');
  await expect(cards).toHaveCount(8);
  await expect(album.getByRole('progressbar')).toHaveCount(8);
  const korv = cards.filter({ has: page.getByRole('heading', { name: 'Pre-17:00 Korv Dash' }) });
  await expect(korv.locator('.polaroid-tier')).toHaveText('Tier 100000');
  await expect(korv.getByRole('progressbar', { name: 'Tier 100001' })).toHaveAttribute('aria-valuenow', '0');
  await expect(korv).toContainText('0 / 1000010000 points');
  await expect(album.getByRole('button', { name: /Partille Coastal/ })).toBeEnabled();
});

test('a legacy best cascade earns its original Polaroid and repeat 5× turns advance it across runs', async ({ page }) => {
  await instrument(page, { gameSeed: 2, progress: { ...emptyProgress, bestCascadeCombo: 6 } });
  await openGame(page);
  await frame(page);
  await controlAnimationFrames(page);
  const settings = page.getByRole('dialog', { name: 'Settings' });
  for (const total of [2, 3]) {
    await playTurn(page, [[7, 4], [8, 4]]);
    expect((await readProgress(page)).totalFivePlusCascades ?? 1).toBe(total - 1);
    await playTurn(page, [[2, 0], [3, 0]]);
    expect((await readProgress(page)).totalFivePlusCascades).toBe(total);
    expect((await readProgress(page)).bestCascadeCombo).toBe(6);
    await page.getByRole('button', { name: 'Pause' }).tap();
    await settings.getByRole('button', { name: total === 2 ? /Restart Run/ : /Back to Home/ }).tap();
  }
  await page.reload();
  await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
  const card = page.getByRole('article').filter({ has: page.getByRole('heading', { name: 'Partille Poke Date' }) });
  await expect(card.locator('.polaroid-tier')).toHaveText('Tier 2');
  await expect(card.getByRole('progressbar', { name: 'Tier 3' })).toHaveAttribute('aria-valuenow', '0');
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
    '/', '/index.html', '/munchies.wasm', '/bootstrap.js', '/background-music.js', '/pwa-updates.js', '/release.json', '/styles.css', '/manifest.webmanifest',
    '/assets/event-puppy-walk.svg', '/assets/event-biltema-store.svg', '/assets/event-car.svg', '/assets/event-rocket.svg',
    '/assets/event-cupcake-schedule.svg', '/assets/event-ps5-couch.svg',
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

  await offlinePage.reload();
  await offlinePage.getByRole('button', { name: 'Play Missions' }).tap();
  await offlinePage.getByRole('button', { name: 'Puppy Pickup' }).tap();
  const objective = offlinePage.getByRole('region', { name: 'Mission objective' });
  await expect(objective).toContainText('5 swaps left');
  await tapSwap(offlinePage, [[6, 0], [7, 0]]);
  await expect(objective).toContainText('4 swaps left');
});
