// Munchies PWA Bootstrap:
// 1. Registers the offline Service Worker and connects the update control
// 2. Installs Safari light-dismiss fallback for <dialog closedby="any">
// 3. Shows subtle iOS Safari "Add to Home Screen" banner when not standalone
// 4. Loads & starts the compiled SwiftWasm binary (`./munchies.wasm`) via JavaScriptKit runtime

import { setupPwaUpdates } from "./pwa-updates.js";
import { setMusicPlaying } from "./background-music.js";

setupPwaUpdates();
window.__munchiesSetMusicPlaying = setMusicPlaying;

// 2. Mandatory Safari fallback for <dialog closedby="any"> light-dismiss
if (!("closedBy" in HTMLDialogElement.prototype)) {
  const isOutside = (e, dialog) => {
    const r = dialog.getBoundingClientRect();
    return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
  };
  for (const dialog of document.querySelectorAll('dialog[closedby="any"]')) {
    let pressedOutside = false;
    dialog.addEventListener("pointerdown", (e) => {
      pressedOutside = isOutside(e, dialog);
    });
    dialog.addEventListener("pointerup", (e) => {
      if (pressedOutside && isOutside(e, dialog)) {
        dialog.close();
      }
      pressedOutside = false;
    });
  }
}

// 3. Subtle iOS Safari "Add to Home Screen" prompt when opened in a regular browser tab
(() => {
  const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
  const isStandalone = window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches;
  let dismissed = false;
  try { dismissed = localStorage.getItem("munchies.installTipDismissed") === "1"; } catch {}
  const banner = document.getElementById("ios-install-banner");
  const dismissBtn = document.getElementById("btn-dismiss-install");

  if (banner && isIOS && !isStandalone && !dismissed) {
    banner.hidden = false;
  }
  dismissBtn?.addEventListener("click", () => {
    if (banner) banner.hidden = true;
    try { localStorage.setItem("munchies.installTipDismissed", "1"); } catch {}
  });
})();

// 4. Content-visibility background pause hook on the canvas stage
(() => {
  const stage = document.getElementById("board-stage");
  if (!stage) return;
  stage.addEventListener("contentvisibilityautostatechange", (event) => {
    window.__munchiesStageSkipped = Boolean(event.skipped);
  });
})();

// 5. Boot SwiftWasm binary (`./munchies.wasm`) with JavaScriptKit runtime
async function bootSwiftWasm() {
  try {
    const { init } = await import("./runtime/index.js");
    await init({ module: fetch("./munchies.wasm") });
    for (const id of ["btn-play", "btn-missions", "btn-home-settings", "btn-scrapbook"]) {
      document.getElementById(id).disabled = false;
    }
  } catch (err) {
    document.getElementById("boot-error").hidden = false;
    console.error("[Munchies] SwiftWasm startup failed:", err);
  }
}

bootSwiftWasm();
