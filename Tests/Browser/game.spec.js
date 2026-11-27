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

async function instrument(page, { sound = false, progress, gameSeed } = {}) {
  await page.addInitScript(({ sound, progress, progressKey, gameSeed }) => {
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
      rasterizedSprites: new Set(),
    });
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
      }
      return fillText.call(this, text, ...args);
    };

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
  }, { sound, progress, progressKey, gameSeed });
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
  await page.getByRole('button', { name: 'Play Craving Trail' }).tap();
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
    const goals = document.querySelector('#stage-goals');
    const cs = getComputedStyle(document.body);
    return {
      height: innerHeight,
      paddingBottom: getComputedStyle(document.querySelector('#screen-game')).paddingBottom,
      screenHeight: document.querySelector('#screen-game').getBoundingClientRect().height,
      canvas: canvas.getBoundingClientRect().toJSON(), backing: [canvas.width, canvas.height],
      hud: document.querySelector('.hud-header').getBoundingClientRect().toJSON(),
      goals: goals.getBoundingClientRect().toJSON(),
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
      const { height, paddingBottom, screenHeight, canvas, backing, hud, goals, footer, overflow, boardTouch, selection, ratio, scroll } = await layout();
      const cellSize = Math.floor(Math.min((canvas.width - 20) / 8, (canvas.height - 20) / 9));
      return screenHeight === height && parseFloat(paddingBottom) >= 24
        && hud.bottom <= goals.top + 1 && goals.bottom <= canvas.top + 1
        && canvas.bottom <= footer.top + 1 && footer.bottom <= height - 23
        && cellSize >= (heightReduction ? 32 : 42)
        && Math.abs(backing[0] - canvas.width * ratio) < 1.1 && Math.abs(backing[1] - canvas.height * ratio) < 1.1
        && overflow === 'hidden' && boardTouch === 'none'
        && selection === 'none' && scroll.every(n => n === 0);
    }).toBe(true);
  }
  await expect(page.locator('#hud-tier')).toHaveText('CRAVING 1');
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
    await expect(page.locator('#stage-swaps')).toHaveText('13 swaps left');
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
  const playButton = page.getByRole('button', { name: 'Play Craving Trail' });
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
  await expect(settings.getByText('Retry Stage')).toBeHidden();
  await page.mouse.click(4, 4);
  await expect(settings).toBeHidden();
});

test('background music loops in a run, pauses with the game, and has an independent saved toggle', async ({ page }) => {
  await instrument(page, { sound: true, progress: emptyProgress });
  await page.goto('/');
  const play = page.getByRole('button', { name: 'Play Craving Trail' });
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
  const opening = (await frame(page)).flat().map(tile => tile.kind);
  const shuffle = page.getByRole('button', { name: /SHUFFLE/ });
  await shuffle.tap();
  await expect(shuffle).toBeDisabled();
  await expect(page.locator('#hud-shuffles')).toHaveText('0/2');
  await expect(page.locator('#hud-score')).toHaveText('0');
  await expect(page.locator('#board-canvas')).toHaveAttribute('aria-busy', 'false');
  findSwap(await frame(page));
  await page.getByRole('button', { name: 'Pause' }).tap();
  await page.getByRole('button', { name: /Retry Stage/ }).tap();
  await expect(shuffle).toBeEnabled();
  await expect(page.locator('#hud-shuffles')).toHaveText('1/2');
  await expect(page.locator('#hud-score')).toHaveText('0');
  await expect(page.locator('#stage-swaps')).toHaveText('13 swaps left');
  expect((await frame(page)).flat().map(tile => tile.kind)).not.toEqual(opening);
});

test('opening the journal pauses a moving board and preserves the pinned story', async ({ page }) => {
  await page.setViewportSize({ width: 430, height: 850 });
  await page.clock.install({ time: 0 });
  await instrument(page, { gameSeed: 2 });
  await openGame(page, { manualFrames: true });
  const story = page.getByRole('region', { name: 'Run story' }).getByRole('status');
  const canvas = page.locator('#board-canvas');
  await playTurn(page, [[2, 1], [3, 1]]);
  await expect(story).toHaveText('Stray puppy spotted');
  await expect(story.locator('.event-travel')).toHaveCSS('animation-name', 'event-walk-in');
  await page.clock.fastForward(60_000);
  await expect(story).toHaveText('Stray puppy spotted');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(story.locator('.event-travel')).toHaveCSS('animation-name', 'none');

  await tapSwap(page, [[4, 6], [5, 6]]);
  await expect(canvas).toHaveAttribute('aria-busy', 'true');
  await page.getByRole('button', { name: 'Journal', exact: true }).tap();
  const journal = page.getByRole('dialog', { name: 'Run Journal' });
  await expect(journal.getByText('Guide it to the bottom row.')).toBeVisible();
  const trip = journal.getByRole('listitem').filter({ hasText: 'Biltema Run' });
  await expect(trip.locator('.event-art')).toHaveCSS('background-image', /event-biltema-store\.svg/);
  await page.evaluate(() => window.munchiesProbe.advanceFrames(120));
  await expect(canvas).toHaveAttribute('aria-busy', 'true');
  await journal.evaluate(dialog => {
    window.munchiesProbe.journalClosed = false;
    dialog.addEventListener('close', () => { window.munchiesProbe.journalClosed = true; }, { once: true });
  });
  await journal.getByRole('button', { name: 'Close journal' }).tap();
  await expect.poll(() => page.evaluate(() => window.munchiesProbe.journalClosed)).toBe(true);
  await advanceAnimationUntil(canvas, 'aria-busy', 'false');
  await expect(story).toHaveText('Stray puppy spotted');
});

test('the Craving Trail clears a stage, plays its bonus, and saves the next stage', async ({ page }) => {
  await instrument(page, { gameSeed: 42 });
  await openGame(page, { manualFrames: true });
  const goals = page.getByRole('region', { name: 'Stage objectives' });
  await expect(goals).toContainText('Biltema Combos');
  await expect(goals).toContainText('0 / 12');
  await expect(page.locator('#chapter-step')).toHaveText('1 / 5');
  for (const swap of [[[4, 0], [4, 1]], [[0, 2], [1, 2]], [[2, 3], [2, 4]]]) await playTurn(page, swap);
  await expect(goals).toContainText('9 / 12');
  await expect(page.locator('#stage-swaps')).toHaveText('10 swaps left');

  await tapSwap(page, [[0, 4], [1, 4]]);
  await expect(page.locator('#board-canvas')).toHaveAttribute('aria-busy', 'true');
  const bonusSeen = await page.evaluate(() => {
    for (let frame = 0; frame < 200; frame++) {
      if (document.querySelector('#stage-swaps').textContent === 'Bonus ×9') return true;
      window.munchiesProbe.advanceFrames(1);
    }
    return false;
  });
  expect(bonusSeen).toBe(true);
  await advanceAnimationUntil(page.locator('#board-canvas'), 'aria-busy', 'false');
  const result = page.getByRole('dialog', { name: 'Craving 1 cleared!' });
  await expect(result).toContainText('Biltema Combos 12/12');
  await expect(result).toContainText('9 bonus power-ups');
  await expect(result.locator('#stage-result-stars')).toHaveAttribute('aria-label', '3 of 3 stars');
  expect(await readProgress(page)).toMatchObject({ highestCravingCleared: 1, cravingStars: 3 });

  await result.getByRole('button', { name: 'Next stage' }).tap();
  await expect(page.locator('#hud-tier')).toHaveText('CRAVING 2');
  await expect(page.locator('#chapter-step')).toHaveText('2 / 5');
  await expect(goals).toContainText('Snores popped');
  await expect(goals).toContainText('Match beside a bubble');
  await expect(page.locator('#hud-snore-count')).toContainText('4/12');
  await page.reload();
  await expect(page.locator('#home-craving')).toHaveText('Craving 2');
  await page.getByRole('button', { name: 'Play Craving Trail' }).tap();
  await expect(page.locator('#hud-tier')).toHaveText('CRAVING 2');
});

test('an unsuccessful stage shows exact progress and Retry restores the goal and budget', async ({ page }) => {
  await instrument(page, { gameSeed: 42, progress: { ...emptyProgress, highestMissionCleared: 3 } });
  await openGame(page, { manualFrames: true });
  const avoiding = [
    [[1, 4], [1, 5]], [[2, 5], [2, 6]], [[1, 4], [2, 4]], [[1, 6], [2, 6]], [[0, 7], [1, 7]],
    [[0, 7], [1, 7]], [[7, 3], [8, 3]], [[4, 0], [5, 0]], [[1, 4], [2, 4]], [[1, 3], [1, 4]],
    [[2, 3], [3, 3]], [[4, 2], [4, 3]], [[0, 0], [1, 0]],
  ];
  for (const swap of avoiding) await playTurn(page, swap);
  const result = page.getByRole('dialog', { name: 'Out of swaps' });
  await expect(result).toBeVisible();
  await expect(result).toContainText('Biltema Combos 6/12');
  await expect(result.getByRole('button', { name: 'Next stage' })).toBeHidden();
  expect((await readProgress(page)).highestCravingCleared).toBeUndefined();
  expect((await readProgress(page)).highestMissionCleared).toBe(3);
  await result.getByRole('button', { name: 'Retry', exact: true }).tap();
  await expect(page.locator('#hud-tier')).toHaveText('CRAVING 1');
  await expect(page.locator('#hud-score')).toHaveText('0');
  await expect(page.locator('#stage-swaps')).toHaveText('13 swaps left');
  await expect(page.getByRole('region', { name: 'Stage objectives' })).toContainText('0 / 12');
  await expect(page.locator('#board-canvas')).toHaveAttribute('aria-busy', 'false');
});

test('the first puppy has a readable opening rescue on a compact phone', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 600 });
  await instrument(page, { gameSeed: 42, progress: { ...emptyProgress, highestCravingCleared: 2, totalPuppiesRescued: 3 } });
  await openGame(page, { manualFrames: true });
  const goals = page.getByRole('region', { name: 'Stage objectives' });
  await expect(goals).toContainText('Match below the puppy');
  await expect(goals).toContainText('0 / 1');
  expect((await frame(page))[7].filter(tile => tile.kind === 'puppy')).toHaveLength(1);
  expect(await goals.evaluate(goal => {
    const bounds = goal.getBoundingClientRect();
    const board = document.querySelector('#board-canvas').getBoundingClientRect();
    return bounds.bottom <= board.top && goal.scrollWidth <= goal.clientWidth;
  })).toBeTruthy();
  await playTurn(page, [[7, 3], [8, 3]]);
  await expect(page.getByRole('dialog', { name: 'Craving 3 cleared!' })).toContainText('Puppies home 1/1');
  await expect(page.locator('#hud-puppies')).toHaveText('4');
});

test('a chapter finale clears both goals, earns a postcard, and opens the next chapter', async ({ page }) => {
  await instrument(page, { gameSeed: 18, progress: { ...emptyProgress, highestCravingCleared: 4 } });
  await openGame(page, { manualFrames: true });
  const objectives = page.getByRole('region', { name: 'Stage objectives' });
  await expect(objectives).toContainText('Biltema Combos');
  await expect(objectives).toContainText('Snores popped');
  await expect(page.locator('#chapter-pips [data-state="finale"]')).toHaveCount(1);
  for (const swap of [[[2, 1], [3, 1]], [[7, 1], [8, 1]], [[4, 3], [4, 4]], [[3, 4], [3, 5]], [[0, 4], [0, 5]]]) {
    await playTurn(page, swap);
  }
  const result = page.getByRole('dialog', { name: 'Craving 5 cleared!' });
  await expect(result).toContainText('Biltema Combos 16/16 · Snores popped 3/3');
  await result.getByRole('button', { name: 'Home', exact: true }).tap();
  await expect(page.locator('#home-craving')).toHaveText('Craving 6');
  await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
  const album = page.getByRole('dialog', { name: "Couple's Scrapbook" });
  await expect(album.getByRole('button', { name: /Trail Dusk/ })).toBeEnabled();
  await album.getByRole('button', { name: 'Close scrapbook' }).tap();
  await page.getByRole('button', { name: 'Play Craving Trail' }).tap();
  await expect(page.locator('#chapter-theme')).toHaveText('Hermanos Taco Night');
  await expect(page.locator('#chapter-step')).toHaveText('1 / 5');
});

test('Teido Spotlight starts with Pad Thai and rewards a real 3× cascade', async ({ page }) => {
  await instrument(page, { gameSeed: 2, progress: { ...emptyProgress, highestCravingCleared: 8 } });
  await openGame(page, { manualFrames: true });
  await expect(page.getByRole('region', { name: 'Stage objectives' })).toContainText('Teido Spotlight');
  expect((await frame(page)).flat().some(tile => tile.kind === 'padThai')).toBe(true);
  await playTurn(page, [[1, 0], [1, 1]]);
  await page.getByRole('button', { name: 'Journal', exact: true }).tap();
  await expect(page.getByRole('dialog', { name: 'Run Journal' }).getByText('Teido added a Korv Rocket.')).toBeVisible();
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
  ['highestCravingCleared', 5, 'Craving Trail Postcards', 'Trail Dusk backdrop'],
];

test('scrapbook has nine milestones with exact unlock boundaries and selectable unlocked themes', async ({ page }) => {
  const below = Object.fromEntries(milestones.map(([key, target]) => [key, target - 1]));
  await instrument(page, { progress: { ...emptyProgress, ...below, highScore: 4000, cravingStars: 8 } });
  await page.goto('/');

  const openScrapbook = async () => {
    await page.getByRole('button', { name: /Couple's Scrapbook/ }).tap();
    await expect(page.getByRole('dialog', { name: "Couple's Scrapbook" })).toBeVisible();
    await expect(page.locator('.polaroid-card')).toHaveCount(9);
  };
  await openScrapbook();
  await expect(page.locator('#scrapbook-trail-stars')).toHaveText('8');
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
  await expect(page.locator('#scrapbook-unlocked-count')).toHaveText('14');
  const theme = page.getByRole('button', { name: /PS5 Neon Glow/ });
  await theme.tap();
  await expect(page.locator('body')).toHaveAttribute('data-theme', 'neonPS5');
  await page.reload();
  await expect(page.locator('body')).toHaveAttribute('data-theme', 'neonPS5');
  await page.getByRole('button', { name: 'Play Craving Trail' }).tap();
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
  await expect(cards).toHaveCount(9);
  await expect(album.getByRole('progressbar')).toHaveCount(9);
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
    expect((await readProgress(page)).totalFivePlusCascades ?? 1).toBe(total - 1);
    await playTurn(page, [[2, 1], [3, 1]]);
    expect((await readProgress(page)).totalFivePlusCascades).toBe(total);
    expect((await readProgress(page)).bestCascadeCombo).toBe(6);
    await page.getByRole('button', { name: 'Pause' }).tap();
    await settings.getByRole('button', { name: total === 2 ? /Retry Stage/ : /Back to Home/ }).tap();
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
  await offlinePage.getByRole('button', { name: 'Play Craving Trail' }).tap();
  await expect(offlinePage.getByRole('region', { name: 'Stage objectives' })).toBeVisible();
  await expect(offlinePage.locator('#hud-tier')).toHaveText('CRAVING 1');
});
