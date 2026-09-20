// ============================================================
// Sideline Service Worker
// ============================================================
// A service worker is a script the browser keeps running in the
// background, separate from the page. Its job here: intercept the
// network requests the app makes and answer from a local cache when
// the network is unavailable.
//
// Why this matters for Sideline specifically: you use it standing at
// a youth soccer field, which is exactly where cell service dies.
// Sideline's own files are these four plus whatever is in
// localStorage, so they must work with zero bars.
//
// Three rules, one per kind of request:
//
//  1. The page itself (a navigation): NETWORK-FIRST with a short
//     timeout. Online, you get the newest build on the first launch
//     after a push. With one flaky bar, you get the cached copy after
//     a few seconds instead of a blank screen.
//
//  2. Other same-origin files and Google Fonts: CACHE-FIRST, refreshed
//     quietly in the background. Fast, and works offline.
//
//  3. Everything else - above all the Google Sheet schedule fetch - is
//     NOT touched. The previous worker cached every GET cache-first,
//     including the sheet, so a re-import handed back the schedule as
//     it was the last time you fetched it: referee swaps made that
//     morning silently never arrived.
// ============================================================

const CACHE_NAME = 'sideline-shell-v4';
const SHELL_ASSETS = ['./', './index.html', './manifest.json', './icon.svg'];
const FONT_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com'];
// The sign-in library, only when accounts are configured. The URL names an
// exact version, so a cached copy can never be stale. Supabase's own API
// (*.supabase.co) is deliberately absent: its answers must always be live.
const PINNED_LIBS = /^https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@\d+\.\d+\.\d+\//;
const NETWORK_TIMEOUT_MS = 3500;

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
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (url.origin === self.location.origin) {
    event.respondWith(req.mode === 'navigate' ? networkFirst(req) : cacheFirst(req));
    return;
  }
  if (FONT_HOSTS.includes(url.hostname) || PINNED_LIBS.test(req.url)) {
    event.respondWith(cacheFirst(req));
  }
  // Anything else falls through to the browser's normal network handling.
});

async function networkFirst(req) {
  const cache = await caches.open(CACHE_NAME);
  const network = fetch(req).then((res) => {
    // A redirected response cannot be replayed for a navigation later, so
    // only a direct 200 is stored.
    if (res && res.ok && !res.redirected) cache.put(req, res.clone());
    return res;
  });
  network.catch(() => { }); // a late failure after the timeout is not an error worth reporting

  const timeout = new Promise((resolve) => setTimeout(resolve, NETWORK_TIMEOUT_MS));
  try {
    const res = await Promise.race([network, timeout]);
    if (res) return res;
  } catch (e) { /* offline: use the cache below */ }

  // The admin console (admin/) is never swapped for the mentor app: with no
  // copy of it cached, the browser's own offline page says what happened.
  const url = new URL(req.url);
  const consolePath = new URL('./admin', self.registration.scope).pathname;
  const isConsole = url.pathname === consolePath || url.pathname.startsWith(consolePath + '/');
  const hit = (await cache.match(req, { ignoreSearch: true })) || (isConsole ? null : await cache.match('./index.html'));
  // Nothing cached yet (very first visit on a slow link): keep waiting on the network.
  return hit || network;
}

async function cacheFirst(req) {
  const cache = await caches.open(CACHE_NAME);
  const hit = await cache.match(req);
  const network = fetch(req).then((res) => {
    // The font stylesheet is requested without CORS, so it comes back
    // "opaque" (status 0, ok false). The old worker only stored ok
    // responses, which is why the fonts never worked offline.
    if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
    return res;
  });
  if (hit) {
    network.catch(() => { });
    return hit;
  }
  return network;
}
