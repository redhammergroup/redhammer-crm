/* Red Hammer CRM offline support: keeps a copy of the app on the device so it opens with no signal.
   Live data (Supabase) and alerts (ntfy) always go to the network and are never cached here. */
const CACHE = "rh-app-v1";
const SHELL = ["./", "./index.html", "./manifest.json", "./icon-192.png", "./icon-512.png", "./apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET") return;
  const u = new URL(r.url);
  if (u.hostname.endsWith("supabase.co") || u.hostname === "ntfy.sh") return;
  if (u.origin === location.origin && u.searchParams.has("check")) return; /* update check must see the real file */

  /* the app page: newest from the network, saved copy if there's no signal (or it takes over 4 seconds) */
  if (r.mode === "navigate" || (u.origin === location.origin && /\/(index\.html)?$/.test(u.pathname))) {
    const net = fetch(r).then(res => { if (res.ok) { const cp = res.clone(); caches.open(CACHE).then(c => c.put("./index.html", cp)); } return res; });
    const slow = new Promise(ok => setTimeout(ok, 4000));
    e.respondWith(
      Promise.race([net, slow])
        .then(res => res || caches.match("./index.html").then(hit => hit || net))
        .catch(() => caches.match("./index.html"))
    );
    return;
  }

  /* icons, fonts and libraries: saved copy first, fetch and keep it if missing */
  e.respondWith(caches.match(r).then(hit => hit || fetch(r).then(res => {
    if (res.ok || res.type === "opaque") { const cp = res.clone(); caches.open(CACHE).then(c => c.put(r, cp)); }
    return res;
  })));
});
