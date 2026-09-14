// ============================================================
// Sideline Service Worker
// ============================================================
// A service worker is a script the browser keeps running in the
// background, separate from the page. Its job here: intercept every
// network request the app makes and answer from a local cache when
// the network is unavailable.
//
// Why this matters for Sideline specifically: you use it standing at
// a youth soccer field, which is exactly where cell service dies.
// Unlike Whistle, Sideline has NO remote data source — everything it
// needs is these four files plus whatever is in localStorage. So the
// strategy here is CACHE-FIRST (serve the stored copy immediately,
// update in the background) rather than Whistle's NETWORK-FIRST.
// Cache-first is faster and works with zero bars; the tradeoff is
// that a code update lands on the *second* launch after you push it.
// ============================================================

const CACHE_NAME = 'sideline-shell-v1';
const SHELL_ASSETS = ['./', './index.html', './manifest.json', './icon.svg'];

self.addEventListener('install', (event) => {
  // waitUntil keeps the worker alive until the promise settles, so the
  // browser doesn't kill us mid-download.
  event.waitUntil(caches.open(CACHE_NAME).then((c) => c.addAll(SHELL_ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  // Delete caches from older versions so storage doesn't grow forever.
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  // Google Fonts and the form link: try network, fall back to cache.
  // Never block app startup on them.
  event.respondWith(
    caches.match(event.request).then((hit) => {
      const network = fetch(event.request)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((c) => c.put(event.request, copy));
          }
          return res;
        })
        .catch(() => hit); // offline and not cached -> undefined, browser shows its own error

      // Cache-first: hand back the stored copy the instant we have one,
      // and let the network request quietly refresh it for next time.
      return hit || network;
    })
  );
});
