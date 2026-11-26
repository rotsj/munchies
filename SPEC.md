# Project Specification: *Munchies* (SwiftWasm PWA on Cloudflare)

## 1. Overview & Design Philosophy
* **App Title / Home Screen Name:** *Munchies*
* **Platform & Deployment:** Progressive Web App (PWA) written in **Swift 6**, compiled to **WebAssembly (`wasm32-unknown-wasi` / SwiftWasm)**, and deployed as static assets on **Cloudflare Pages** (with optional Cloudflare Workers / KV for shared couple leaderboards).
* **Target Hardware:** Mobile Safari on **iPhone 14 Pro Max** and **iPhone 17 Pro Max** (installed to Home Screen via `display: "standalone"`, Portrait-locked, 120Hz ProMotion `requestAnimationFrame` loop, `viewport-fit=cover` with `env(safe-area-inset-*)` support).
* **Core Loop:** Swap adjacent snack tiles on an $8 \times 9$ grid to match 3 or more, trigger cascading combos, manage the **Teido Snore** hazard, rescue stray **Puppies**, and ride alternating **Cupcake & Teido Craving Surges** across endless **Night Owl Tiers**.
* **Tone & Aesthetic:** Cozy, playful, slightly goofy, and ultra-responsive—relying on juicy spring physics, tactile WebAudio cues, and smooth 2D Canvas rendering without heavy meta-game bloat.

---

## 2. Tech Stack & Architecture
* **Language & Toolchain:** Swift 6 compiled via **SwiftWasm** (`swiftwasm.org` toolchain + `Carton` or `SwiftPM` Wasm build pipeline) + `JavaScriptKit` for zero-overhead DOM, Canvas 2D, and WebAudio interop.
* **Architectural Boundary:**
  * **Pure Swift Engine (`Engine/`):** Zero browser/JS imports. Deterministic state machine emitting discrete `BoardStep` events—100% testable natively on macOS via `swift test` (`XCTest`) before compiling to `.wasm`.
  * **SwiftWasm Renderer & Shell (`WebRenderer/`):** Bridges Swift to HTML5 `<canvas>` (HiDPI `devicePixelRatio` scaled for Pro Max Retina displays) and lightweight semantic DOM/CSS overlays for HUD, Scrapbook, and Settings.
* **PWA & Offline Capabilities:**
  * `manifest.webmanifest` (`display: standalone`, `orientation: portrait`, custom app icons, theme color).
  * Service Worker (`sw.js`) pre-caching the `.wasm` binary, JS glue, SVG/PNG sprite sheets, and synthesized/encoded audio so the game launches instantaneously and runs 100% offline.
  * The home screen Settings menu can check for a new release and restart into it after all assets are downloaded. Saved scores and settings carry over. Players can retry an offline check after reconnecting.
* **Hosting:** **Cloudflare Pages** (static `dist/` bundle with Brotli/Gzip compression for fast `.wasm` cold loads and automatic edge caching).
* **Persistence:** Browser `localStorage` / `IndexedDB` wrapper (`ProgressStore.swift`) for high scores, rescued puppy count, unlocked Polaroid milestones, and audio toggles.
* **Audio & Feedback:**
  * **WebAudio API (`AudioContext`):** Pitch-escalating marimba/pop synthesis (`+1` semitone per cascade depth) + short, volume-normalized comedic sound effects (`< 0.6s`).
  * **Visual Micro-Shake & Spring Squash:** Since iOS Safari does not expose the Vibration API to PWAs, tactile impact is reinforced via crisp `60–120Hz` micro-screen shakes, scale-bounce animations, and synchronized WebAudio pops.

---

## 3. Core Game Mechanics & Character Identity

### A. Board & Standard Tile Roster
* **Grid Dimensions:** `8 columns × 9 rows` (72 cells total), sized for Pro Max tall viewports with generous thumb clearance above the iOS Home Indicator.
* **Standard Tiles (6 Types):**
  1. **Cupcake** — Pink frosting with sprinkles (represents her).
  2. **Teido** — Upright purple-skinned potato (`po-tato`) with tiny glasses (represents him).
  3. **Hermanos Taco** — Crunchy taco shell loaded with toppings.
  4. **Partille Poke Bowl** — Fresh salmon, avocado, and edamame poke bowl.
  5. **Biltema Combo** — Iconic blue-and-white soft-serve ice cream cone and hotdog (*korv*).
  6. **Big Mac** — Classic double-decker burger (Cupcake's favorite).
* *(Note: **Pad Thai** appears as Teido's signature bonus tile/reward during Teido Craving Surges and special combos.)*

### B. Special Power-Up Tiles (Classic Match Rules)
* **Match 4 in a Line $\rightarrow$ Biltema Korv Rocket:** Clears an entire row or column (oriented perpendicular to the player's swipe direction) with a sizzle trail.
* **Match 5 in an L or T Shape $\rightarrow$ Hermanos Fiesta Bomb:** Explodes in a $3 \times 3$ radius, scattering salsa/confetti particles.
* **Match 5 in a Straight Line $\rightarrow$ Golden Soft-Ice Swirl:** Swapping with any adjacent tile zaps all tiles of that type off the board.
* **Special + Special Combos:** Swapping any two special tiles triggers an amplified board-wide clear (e.g., Korv Rocket + Fiesta Bomb clears 3 rows and 3 columns simultaneously).

### C. Live "Co-op Corner" Avatars (Reactive Top HUD)
Animated portraits of **Cupcake** and **Teido** flank the top HUD next to the Score and Snore-O-Meter, reacting dynamically to board events:
* **Cupcake Avatar States:**
  * *Idle:* Smiling with a subtle sparkle animation.
  * *Snore Alert (5+ Bubbles):* Covers her ears with an annoyed/sleepy glare directed across the HUD at Teido.
  * *Big Mac / Puppy Rescue:* Cheers with heart-eyes whenever Big Macs are matched in a combo or a Puppy reaches the bottom row.
* **Teido Avatar States:**
  * *Idle (PS5 Gaming Mode):* Happily holding a white/black dual-sense style controller with subtle LED glow and snacking on Pad Thai.
  * *Snore Meter Rising:* Drops the controller and nods off with a cartoon `Zzz` bubble right before a Snore Bubble spawns onto the board.
  * *Big Combo (`4x+` Cascade):* Wakes up startled, grabs his controller, and flashes a celebratory *"Level Clear!"* grin.

### D. Twist 1: The "Teido Snore" Hazard (Light Sleeper Mechanic)
* **Spawn Mechanics:** A compact **Zzz / Decibel Gauge** in the top HUD tracks turns until the next snore. Every $N$ non-cascade moves (scaling by Tier), a **Snore Bubble (`Zzz`)** drifts onto a random standard tile, locking it in a drowsy haze.
  * Locked tiles **cannot be swapped** directly, though they still fall downward with gravity when tiles below them clear.
  * **Double-Zzz Bubbles** (Tier 4+) require 2 adjacent matches to pop.
  * **Drifting Bubbles** (Tier 8+) float upward by 1 row every 3 turns if left unpopped.
* **Clearing & Counter-Play:**
  * Making any match orthogonally adjacent to a Snore Bubble pops it with a soft comical *"snort-gasp"* sound.
  * **Cupcake Pacifier Passive:** Matching **4 or more Cupcake tiles** in a single move emits a pink sparkle wave that automatically pops the oldest Snore Bubble anywhere on the board.
* **Lose Condition:** If **12 or more tiles** become locked by Snore Bubbles simultaneously, the run ends (*"Teido Woke the Whole Neighborhood!"*).

### E. Twist 2: Stray Puppy Cameos (Drop-Down Bonus)
* **Trigger:** Crossing the current Tier's Puppy score interval (or triggering a `4x+` cascade) slides a cute **Puppy Tile** into a random top-row slot with a paw-print trail and happy *yip*.
* **Objective:** Guide the Puppy to the bottom row (`row = 8`) by clearing tiles underneath it.
* **Reward:** Reaching the bottom triggers a joyful bark, showers hearts across the screen, clears a $3 \times 3$ (or $5 \times 5$ at Tier 13+) blast radius around the drop zone, awards massive bonus points, and increments the persistent **Puppies Rescued** counter.

---

## 4. Endless Progression & Character Craving Surges

Instead of finite levels or energy timers, a single run advances infinitely through numbered **Night Owl Tiers** (`Tier 1`, `Tier 2`, `Tier 3`... $\infty$).

### A. Character-Themed Craving Surges (Alternating Tiers)
Shared snacks (**Hermanos Tacos**, **Partille Poke Bowls**, and **Biltema Combos**) grant equal base rewards across all Tiers. Every 3rd Tier activates a character spotlight for one full Tier duration:

* **Cupcake's Craving Surge (`Tier 3, 9, 15...`):**
  * **Big Mac & Cupcake Bonus:** Matching **Big Macs** or **Cupcakes** awards `+25%` bonus points.
  * **Puppy Magnet:** Puppy spawn frequency increases by `30%` for the duration of the Tier.
* **Teido's Craving Surge (`Tier 6, 12, 18...`):**
  * **Pad Thai Feast:** **Pad Thai** bonus tiles spawn onto the board (matching adjacent to or swapping with Pad Thai awards `+25%` bonus points and clears an extra cross `+` of tiles).
  * **PS5 "Combo Multiplier" Buff:** Teido's controller lights up; every `3x+` cascade triggers a **"Combo Achievement Unlocked!"** badge that spawns an extra **Biltema Korv Rocket** onto the board.

### B. Tier Advancement & Breathing Room
* **Tier Progress Bar:** Fills as tiles are cleared (`tierTarget = baseTarget * pow(1.18, Double(tier - 1))`).
* **Tier Up Celebration:** Filling the bar pops all active **Snore Bubbles** for bonus points and adds an illustrated snack event to the run history (e.g., *"Afternoon Biltema Run!"*, *"Pre-17:00 Korv Dash!"*, *"Hermanos Taco Feast!"*, *"Partille Poke Craving!"*). Play continues while the event is displayed.
* **Lifeline & Fair Lose Conditions:**
  * Players start with **1 Emergency Shuffle** (spinning *Biltema Hotdog* icon, max capacity `2`), earning `+1` back every **3rd Tier** completed.
  * A run ends only when: (1) **12+ tiles** are locked by Snore Bubbles simultaneously, or (2) **0 valid swaps** remain and `availableShuffles == 0`.

### C. Multi-Layered Difficulty Curve

| Tier Range | Snore Spawn Cadence | Snore Bubble Variants | Base Puppy Cadence | Board & Scoring Dynamics |
| :--- | :--- | :--- | :--- | :--- |
| **Tiers 1–3** *(Warm-Up)* | 1 bubble every **6 moves** | Standard 1-hit bubble | Every **12,000 pts** *(faster in Tier 3)* | `1.0x` base multiplier; high match-assist spawn bias. |
| **Tiers 4–7** *(Getting Cozy)* | 1 bubble every **5 moves** | Standard + **Double-Zzz** (2 hits) | Every **20,000 pts** | `1.5x` base multiplier; neutral spawn weighting. |
| **Tiers 8–12** *(Light Sleeper Alert)* | 1 bubble every **4 moves** | Standard + Double-Zzz + **Drifting** (rises 1 row / 3 turns) | Every **30,000 pts** (up to **2 puppies** at once) | `2.0x` base multiplier; mild anti-clump spawning requires intentional special setups. |
| **Tiers 13+** *(Deep REM Overtime)* | Caps at **1 bubble every 3 moves** (hard ceiling) | Full mix (capped density) | Every **40,000 pts** (rescuing clears $5 \times 5$) | Multiplier scales `+0.25x` per tier infinitely. |

### D. Couple's Milestone Scrapbook (Passive Meta-Progression)
A gallery view accessible from the Home Screen that shows eight illustrated Polaroid tracks. Tier 1 keeps the original requirements and cosmetic rewards:
1. **Pre-17:00 Korv Dash** — *Score 10,000 cumulative points* (Unlocks Biltema blue-and-white board trim).
2. **Cupcake's Big Mac Run** — *Match 100 Big Mac tiles* (Turns the brief particle burst on Big Mac matches gold).
3. **Teido's Pad Thai & PS5 Night** — *Trigger 10 Teido Craving Surges* (Unlocks neon controller-glow backdrop).
4. **Hermanos Taco Tuesday** — *Create 15 Fiesta Bombs* (Unlocks warm fiesta sunset backdrop).
5. **Partille Poke Date** — *Trigger a 5x cascade combo* (Unlocks coastal pastel backdrop).
6. **First Puppy Adopted** — *Rescue 1 Puppy* (Adds a tiny sleeping puppy next to Cupcake's avatar).
7. **Pack Leader** — *Rescue 25 Puppies* (Unlocks Puppy Paw tile trail effect).
8. **Survived Teido's Snoring** — *Pop 50 Snore Bubbles* (Unlocks cozy midnight-blue "Light Sleeper" theme).

Each track always shows its next tier. Tier `n` asks for `n` times the first goal in additional progress, so Korv Dash reaches Tier 2 at 30,000 lifetime points and Tier 3 at 60,000. Surplus counts toward the next goal. Partille Poke Date counts each turn that reaches a cascade of 5× or more once. A legacy save with a qualifying best cascade starts with one qualifying turn. The album shows tiers earned without a completion cap.

### E. Optional Snack Runs

- After successful swaps **10, 35, 60, ...**, the game offers the Snack Runs that have a verified route on the settled board. Each offer can be accepted, skipped, or dismissed by making another successful swap or an emergency shuffle. Invalid swaps leave the offer available.
- Accepting a challenge gives the player up to **six successful swaps** to complete it. Failed attempts, time spent, and emergency shuffles do not use that allowance. The player can leave a challenge early. Skipping, leaving, and expiring carry no penalty. The next offer follows the same swap schedule.
- **Biltema Dash.** Clear the three cells marked with receipts. Matches and blasts collect receipts from the cells they clear. The markers stay on those cells until collected, including through gravity and shuffles. The reward is a horizontal **Korv Rocket**.
- **Partille Poke Order.** Match the displayed first ingredient, then match Partille Poke on a later successful swap. The order favors Hermanos Taco when a route is available. Each swap advances at most one ingredient, including through cascades. Blast damage alone does not count as a match. The reward is a **Fiesta Bomb**.
- An accepted Snack Run uses the run event area to show its goal and swaps left. Completion places one reward on an ordinary, unlocked snack, favoring a tile that can take part in a match. If no tile is eligible, placement waits for a later successful swap. Normal scoring and tier progression continue throughout. Ending the game clears the Snack Run.

---

## 5. Board Generation & Dynamic Refill Algorithms

To prevent both accidental infinite cascades and cheap RNG deadlocks, `Match3Engine` uses **Constraint-Aware Weighted Generation** governed by `SpawnDifficultyProfile`.

### A. Initial Board Generation (`Tier 1` Start)
1. **Zero Pre-Existing Matches:** Populate `(row 0..8, col 0..7)` sequentially, excluding any tile type that already occupies both `(r, c-1)` & `(r, c-2)` or `(r-1, c)` & `(r-2, c)`.
2. **Guaranteed Opening Swaps ($\ge 3$):** Validate with `MoveValidator.findAllValidMoves()`. If fewer than 3 valid swaps exist, perform targeted cell swaps until at least 3 legal moves are present.

### B. Continuous Refill ("The Craving Director")
Whenever tiles clear and gravity drops remaining tiles downward, `TileSpawner` fills empty top slots (`emptySlotsByCol`) from bottom-most empty row upward using dynamic weights (`baseWeight = 100`) adjusted by three Tier-scaled levers:

1. **Match-Assist Bias (`matchAssistBonus`):** Inspects adjacent tiles below/beside the empty slot. If placing tile type $T$ creates a 2-in-a-row setup, adds `matchAssistBonus` (`+45` at Tier 1 down to `-20` at Tier 10+).
2. **Clump Affinity (`clumpAffinity`):** Adjusts weight when identical tiles sit orthogonally adjacent (`+15` at Tier 1 to help form 4/5-matches easily; `-25` at Tier 10+ to spread tiles apart and demand multi-step planning).
3. **Cupcake Mercy Weight:** When `activeSnoreCount >= cupcakeMercyThreshold`, boosts Cupcake spawn weight to `125` (Tiers 1–3) or `105` (Tiers 4+) so players always have a fair path to clear snoring hazards.

### C. Hard Safety Guardrails
* **Silent Deadlock Rescue:** After a refill settles, if `MoveValidator.findAllValidMoves().isEmpty`, `TileSpawner` silently re-rolls the newly spawned top rows once using a guaranteed-match seed before resorting to consuming an Emergency Shuffle.
* **Cascade Depth Cap (`maxAutoCascadeDepth = 6`):** If a single player move reaches 6 consecutive automatic cascades, `TileSpawner` switches to **Anti-Match Mode** (excluding any tile that would immediately complete a 3-match on landing) so the board settles cleanly and returns control to the player.

```swift
// Sources/Engine/TileSpawner.swift
public struct SpawnDifficultyProfile: Sendable {
    public let tier: Int
    public let matchAssistBonus: Int       // +45 at Tier 1 -> -20 at Tier 10+
    public let clumpAffinity: Int          // +15 at Tier 1 -> -25 at Tier 10+
    public let cupcakeMercyThreshold: Int  // Snore count needed to boost Cupcake spawns
    public let maxAutoCascadeDepth: Int    // Caps runaway auto-cascades at 6

    public static func forTier(_ tier: Int) -> SpawnDifficultyProfile {
        let clamped = min(max(tier, 1), 15)
        return SpawnDifficultyProfile(
            tier: tier,
            matchAssistBonus: max(-20, 50 - (clamped * 5)),
            clumpAffinity: max(-25, 20 - (clamped * 3)),
            cupcakeMercyThreshold: tier <= 3 ? 3 : 5,
            maxAutoCascadeDepth: 6
        )
    }
}
6. Mobile Safari PWA Ergonomics & Audio Spec
A. iPhone 14 Pro Max & 17 Pro Max Viewport & Safe Areas
HTML Meta & CSS:

<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">

<meta name="apple-mobile-web-app-capable" content="yes">

<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">

The page uses `height: 100dvh`, `overflow: hidden`, and disabled text selection. The board disables browser touch gestures for swaps, while the event history accepts horizontal panning.

Safe-Area Layout Zones:

Top Safe Area (padding-top: env(safe-area-inset-top)): Clears the Dynamic Island; houses the Co-op Corner Avatars (Cupcake & Teido), Current Score, High Score, Pause button, Snore-O-Meter, and Tier Progress Bar.

Center Stage: A Retina-scaled HTML5 canvas shows the 8 × 9 grid on a solid neutral surface with subtle grid lines. Each snack is recognized by its own silhouette and dominant color.

Run Events: A horizontally scrollable strip between the board and the thumb dock keeps recent run events available for review. Cards stay in view for at least three seconds during automatic playback. Walking puppies, a car arriving at Biltema, and other illustrations accompany their event text. Point and combo callouts appear on the board. The strip follows the system's reduced-motion setting.

* **Cupcake's 60% Rule** appears the first time Tier 1 progress reaches or passes 60%, including a turn that advances past Tier 1. A study notebook opens beside her work laptop.
* **Gemini Mode** appears the first time a single turn matches both Cupcakes and Big Macs, including matches in different waves of that turn. The two snacks trade places in the card.
* **PS5 Couch Mode** appears on the first `4x+` combo wake-up in a run. The TV lights up as Teido plays from the couch. The couch scene also accompanies later Teido Craving Surge cards.

Bottom Safe Area (padding-bottom: max(24px, env(safe-area-inset-bottom))): Dedicated thumb-rest zone keeping fingers clear of the iOS Home Indicator; displays active Cascade Multiplier, Puppies Rescued counter, and the Emergency Shuffle badge.

B. Touch & Canvas Animation Feel
Pointer Events (pointerdown, pointermove, pointerup): Supports both drag-to-swap (triggers immediately once finger crosses 35% of tile width without lifting) and tap-to-select + tap-adjacent. Selected tiles scale to 1.12x with a damped spring curve.

Custom Vector / Layered Canvas Art: Crisp SVG sprites pre-rendered onto offscreen canvases at boot for 120fps blitting, complete with subtle idle animations (Teido gaming/blinking, Cupcake sparkles, Puppy tail wagging).

C. WebAudio Synthesis & SFX (Goofy, Not Overwhelming)
iOS Safari Audio Unlock: Initialize/resume AudioContext on the first pointerdown gesture so sound works reliably in standalone PWA mode.

Pitch-Escalating Match Pop: Procedural WebAudio oscillator/marimba pop rising by 1 semitone per cascade (C5 -> D5 -> E5 -> G5...).

Short Comedic SFX (< 0.6s, volume-normalized):

Snore Bubble Spawn: Brief, muffled cartoon "krrrr-snort".

Snore Popped: Tiny squeaky pillow-pat / "shhh!".

Puppy Spawn / Rescue: Cheerful puppy "yip!" and warm chime.

Teido Surge / Combo: Subtle PS5-inspired crisp dual-chime "trophy/achievement" blip.

Background Music: A quiet 32-bar groove with warm keys, rounded bass, and brushed percussion plays behind active runs through the same WebAudio context. Playback pauses in Settings, at game over, on the Home screen, and when the app is hidden. The loop is synthesized locally and works offline.

Settings Toggles: Independent switches in the Pause/Settings overlay for Sound Effects, Background Music, Goofy Snore Sounds, and Screen Shake.

7. Project Directory Structure & Cloudflare Deployment
Plaintext
Munchies/
├── Package.swift                      # SwiftPM manifest (Engine target + SwiftWasm App target)
├── Makefile / build.sh                # Builds .wasm via SwiftWasm, bundles static assets to dist/
├── wrangler.toml                      # Cloudflare Pages configuration (pages_build_output_dir = "dist")
├── public/
│   ├── index.html                     # Viewport-fit=cover, Apple PWA meta tags, Canvas + HUD mount
│   ├── styles.css                     # Safe-area CSS variables, glassmorphic HUD & Scrapbook styles
│   ├── manifest.webmanifest           # PWA standalone manifest, icons, portrait orientation
│   ├── sw.js                          # Offline Service Worker caching .wasm, assets & audio
│   └── assets/                        # Crisp SVG snack sprites, avatars, and short SFX clips
├── Sources/
│   ├── Engine/                        # Pure Swift, ZERO JavaScriptKit imports (runs on macOS XCTest)
│   │   ├── TileModel.swift            # TileType, SpecialModifier, SnoreState, Puppy, PadThai
│   │   ├── DifficultyConfig.swift     # Night Owl Tier & Craving Surge scaling parameters
│   │   ├── BoardState.swift           # 8x9 grid, deterministic RNG seed, match detector
│   │   ├── TileSpawner.swift          # SpawnDifficultyProfile & weighted refill generator
│   │   ├── CascadeResolver.swift      # Step-by-step match, gravity, snore & puppy resolver
│   │   ├── MoveValidator.swift        # Swap legality, hint finder, deadlock shuffle
│   │   └── BoardStep.swift            # Discrete animation & avatar reaction events
│   └── App/                           # SwiftWasm + JavaScriptKit browser bridge
│       ├── Main.swift                 # Entry point, requestAnimationFrame loop, PWA bootstrap
│       ├── CanvasRenderer.swift       # HiDPI 2D Canvas board, sprites, particles & spring physics
│       ├── InputHandler.swift         # Pointer drag-to-swap & tap-to-swap gesture recognizer
│       ├── DOMController.swift        # Updates Swift-driven HUD, Avatars, Scrapbook & Modals
│       ├── WebAudioManager.swift      # WebAudio API pitch-shifted pops & comedic SFX
│       └── StorageManager.swift       # localStorage persistence for scores, puppies & milestones
└── Tests/
    └── EngineTests/
        └── Match3EngineTests.swift    # Native XCTest suite (matches, specials, surges, deadlocks)
8. Agent Execution Milestones
Milestone 1 — Pure-Swift Engine & Native Unit Tests: Implement Sources/Engine/ (TileModel, DifficultyConfig, BoardState, TileSpawner, CascadeResolver, MoveValidator, BoardStep) with deterministic seeded RNG and full XCTest coverage (swift test on macOS) verifying match detection, special combos, Snore Bubble lifecycle, Puppy drop-downs, Cupcake/Teido Craving Surges, and deadlock prevention.

Milestone 2 — SwiftWasm Build Pipeline & HiDPI Canvas Renderer: Configure Package.swift for SwiftWasm (JavaScriptKit), build CanvasRenderer and InputHandler consuming BoardStep arrays sequentially at 120fps with drag-to-swap responsiveness and crisp SVG snack/avatar art.

Milestone 3 — Reactive Avatars, WebAudio & PWA Offline Shell: Wire up DOMController (reactive Cupcake & Teido portraits, Snore-O-Meter, Tier Progress Bar, Scrapbook, Settings), WebAudioManager (with procedural WebAudio synthesis so zero external audio files are required to play immediately), manifest.webmanifest, and sw.js.

Milestone 4 — Cloudflare Pages Packaging & Install Prompt: Add wrangler.toml and build script outputting a compressed static dist/ bundle ready for wrangler pages deploy dist, plus a subtle iOS Safari "Add to Home Screen" banner when opened in a regular browser tab.
