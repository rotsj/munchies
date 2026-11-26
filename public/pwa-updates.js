function waitForActivation(worker) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error("Update download timed out")), 45_000);

    function finish(error) {
      clearTimeout(timer);
      worker.removeEventListener("statechange", check);
      if (error) reject(error);
      else resolve();
    }

    function check() {
      if (worker.state === "activated") finish();
      if (worker.state === "redundant") finish(new Error("Update installation failed"));
    }

    worker.addEventListener("statechange", check);
    check();
  });
}

async function downloadUpdate(registration, status) {
  let installing = registration.installing;
  const rememberWorker = () => { installing = registration.installing ?? installing; };
  registration.addEventListener("updatefound", rememberWorker);
  try {
    await registration.update();
    const worker = registration.installing ?? registration.waiting ?? installing ?? registration.active;
    if (!worker) throw new Error("No service worker available");
    if (worker.state !== "activated") {
      status.textContent = "Downloading update…";
      await waitForActivation(worker);
    }
  } finally {
    registration.removeEventListener("updatefound", rememberWorker);
  }
}

export function setupPwaUpdates() {
  const button = document.getElementById("btn-check-updates");
  const status = document.getElementById("update-status");
  const pageBuild = document.querySelector('meta[name="munchies-build"]')?.content;
  const workers = navigator.serviceWorker;
  if (!workers) {
    if (button) button.disabled = true;
    if (status) status.textContent = "Updates are unavailable in this browser.";
    return;
  }

  let registration;
  const register = () => registration ??= workers.register("./sw.js", { updateViaCache: "none" }).catch(error => {
    registration = undefined;
    throw error;
  });
  window.addEventListener("load", () => { register().catch(() => {}); }, { once: true });
  if (!button || !status || !pageBuild) return;

  let updateReady = false;
  button.addEventListener("click", async () => {
    button.disabled = true;
    if (updateReady) {
      status.textContent = "Restarting Munchies…";
      window.location.reload();
      return;
    }

    status.textContent = "Checking for updates…";
    try {
      if (!navigator.onLine) throw new Error("Offline");
      await downloadUpdate(await register(), status);
      // The controlling worker serves this marker and the next navigation from the same release cache.
      const response = await fetch("./release.json", { cache: "no-store" });
      if (!response.ok) throw new Error("Release marker unavailable");
      const { build } = await response.json();
      if (typeof build !== "string" || !/^[a-f0-9]{20}$/.test(build)) throw new Error("Invalid release marker");
      updateReady = build !== pageBuild;
      if (updateReady) button.textContent = "Update now";
      status.textContent = updateReady ? "Update ready. Restart Munchies to use it." : "Munchies is up to date.";
    } catch {
      status.textContent = navigator.onLine
        ? "Couldn't check for updates. Try again."
        : "You're offline. Connect to check for updates.";
    } finally {
      button.disabled = false;
    }
  });
}
