# Project Specification: *Munchies* (SwiftWasm PWA on Cloudflare)

## 1. Overview & Design Philosophy
* **App Title / Home Screen Name:** *Munchies*
* **Platform & Deployment:** Progressive Web App (PWA) written in **Swift 6**, compiled to **WebAssembly (`wasm32-unknown-wasi` / SwiftWasm)**, and deployed as static assets on **Cloudflare Pages** (with optional Cloudflare Workers / KV for shared couple leaderboards).
* **Target Hardware:** Mobile Safari on **iPhone 14 Pro Max** and **iPhone 17 Pro Max** (installed to Home Screen via `display: "standalone"`, Portrait-locked, 120Hz ProMotion `requestAnimationFrame` loop, `viewport-fit=cover` with `env(safe-area-inset-*)` support).
* **Core Loop:** Swap adjacent snack tiles on an $8 \times 9$ grid to match 3 or more, trigger cascading combos, manage the **Teido Snore** hazard, rescue stray **Puppies**, and clear numbered stages along the **Craving Trail**.
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

## 4. The Craving Trail

Craving stages form the main game. The home screen resumes at the first uncleared stage. Five stages make a chapter with a two-objective finale. Biltema Run, Hermanos Taco Night, Partille Poke Date, and PS5 After Dark repeat as numbered encores. Stage numbers continue across loops.

| Chapter slot | Objective | Opening setup |
| --- | --- | --- |
| 1 | Collect the chapter's snack | Normal opening board |
| 2 | Pop four snore bubbles | Four bubbles placed in separate areas with nearby matching opportunities |
| 3 | Guide one puppy to the bottom | The puppy starts one row from home with at least two visible opening swaps that can rescue it |
| 4 | Cupcake or Teido Spotlight | Cupcakes and Big Macs count twice for Cupcake, and puppies visit more frequently. Teido starts with Pad Thai and a Korv Rocket. A 3× cascade grants the existing PS5 Combo Perk. |
| 5 | Collect the chapter's snack and finish a second goal | Second goals rotate through snores, a Fiesta Bomb, a puppy, and a special-tile combination. Relevant pieces are ready on the opening board. |

Legal swaps spend one move. Failed swaps and the emergency shuffle leave the budget alone. Cleared snacks count from matches, specials, and rescue blasts. Popped snores, rescues, and qualifying special activations each count once. Stage goals and the swap budget stay in view above the board. After idle play, the hint favors visible moves that advance an unfinished goal.

Completing every objective clears the stage, including on its final swap. Each spare swap adds one rocket or bomb to a chain of bonus detonations using the normal blast and scoring rules. A clear earns one star, rising to two with at least two spare swaps or three with at least five. The game saves the clear and stars before showing the result. Failure shows the exact progress on each objective. Retry starts a fresh seeded board at the same stage and uses the same budget.

The Couple's Scrapbook keeps its illustrated tracks and cosmetic unlocks. Craving Trail Postcards advances with chapter finales and unlocks the Trail Dusk backdrop after the first finale. Each track keeps an uncapped sequence of next goals. Teido Spotlight clears add to the existing PS5 scrapbook track.

---

## 5. Board Generation & Dynamic Refill Algorithms

To prevent both accidental infinite cascades and cheap RNG deadlocks, `Match3Engine` uses **Constraint-Aware Weighted Generation** governed by `SpawnDifficultyProfile`.

### A. Initial Board Generation
1. **Zero Pre-Existing Matches:** Populate `(row 0..8, col 0..7)` sequentially, excluding any tile type that already occupies both `(r, c-1)` & `(r, c-2)` or `(r-1, c)` & `(r-2, c)`.
2. **Guaranteed Opening Swaps ($\ge 3$):** Validate with `MoveValidator.findAllValidMoves()`. If fewer than 3 valid swaps exist, perform targeted cell swaps until at least 3 legal moves are present.

### B. Continuous Refill ("The Craving Director")
Whenever tiles clear and gravity drops remaining tiles downward, `TileSpawner` fills empty top slots (`emptySlotsByCol`) from bottom-most empty row upward using dynamic weights (`baseWeight = 100`) adjusted by three Tier-scaled levers:

1. **Match-Assist Bias (`matchAssistBonus`):** Inspects adjacent tiles below/beside the empty slot. If placing tile type $T$ creates a 2-in-a-row setup, adds `matchAssistBonus` (`+45` at Tier 1 down to `-20` at Tier 10+).
2. **Clump Affinity (`clumpAffinity`):** Adjusts weight when identical tiles sit orthogonally adjacent (`+15` at Tier 1 to help form 4/5-matches easily; `-25` at Tier 10+ to spread tiles apart and demand multi-step planning).
3. **Cupcake Mercy Weight:** When `activeSnoreCount >= cupcakeMercyThreshold`, boosts Cupcake spawn weight to `125` (Tiers 1–3) or `105` (Tiers 4+) so players always have a fair path to clear snoring hazards.

4. **Objective assistance:** Trail refills mildly favor the current required snack. During the last three swaps, with six or fewer snack credits missing, that weight rises. The anti-match cap still applies.

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

The page uses `height: 100dvh`, `overflow: hidden`, and disabled text selection. The board disables browser touch gestures for swaps. The Run Journal scrolls vertically inside its dialog.

Safe-Area Layout Zones:

Top Safe Area (padding-top: env(safe-area-inset-top)): Clears the Dynamic Island; houses the Co-op Corner Avatars (Cupcake & Teido), current score, swap budget, stage goals, Snore-O-Meter, and chapter progress.

Center Stage: A Retina-scaled HTML5 canvas shows the 8 × 9 grid on a solid neutral surface with subtle grid lines. Each snack is recognized by its own silhouette and dominant color.

Run Story pins one illustrated headline above the board on tall viewports. Automatic story changes are at least six successful swaps apart. The selected moment stays in place until the next one, and opening the Run Journal pauses play for reading. The journal keeps the full text of up to 24 recent moments and records Teido's first snore once per stage. Point and combo callouts appear on the board. Story animations follow the system's reduced-motion setting.

* **Cupcake's 60% Rule** appears when average stage objective progress first reaches 60%. A study notebook opens beside her work laptop.
* **Gemini Mode** appears the first time a single turn matches both Cupcakes and Big Macs, including matches in different waves of that turn. The two snacks trade places in the card.
* **PS5 Couch Mode** appears on the first `4x+` combo wake-up in a run. The TV lights up as Teido plays from the couch. The couch scene also accompanies Teido Spotlight introductions.

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
