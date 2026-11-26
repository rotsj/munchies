const CACHE_PREFIX = "munchies-pwa-";
const BUILD_ID = /* BUILD_ID */ "dev";
const PRECACHE_ASSETS = /* PRECACHE_ASSETS */ [];
const cacheName = CACHE_PREFIX + BUILD_ID;

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName);
    try {
      await cache.addAll(PRECACHE_ASSETS.map(url => new Request(url, { cache: "reload" })));
    } catch (error) {
      await caches.delete(cacheName);
      throw error;
    }
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys
      .filter(key => key.startsWith(CACHE_PREFIX) && key !== cacheName)
      .map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET" || new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith((async () => {
    const cache = await caches.open(cacheName);
    const cached = await cache.match(event.request, { ignoreSearch: true });
    if (cached) return cached;
    if (event.request.mode === "navigate") {
      return fetch(event.request).catch(async () => (await cache.match("./")) ?? Response.error());
    }
    return fetch(event.request);
  })());
});
