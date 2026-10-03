/* Лаборатория Сириус: работа без интернета.
   Страница — сначала из сети (чтобы обновления приходили сразу), без сети — из кэша.
   Иконки, манифест и шрифты — из кэша, если они там уже есть. */
const V='lab-sirius-v1';
const CORE=['./','./index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png','./apple-touch-icon.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const r=e.request;if(r.method!=='GET')return;
  const u=new URL(r.url);
  if(r.mode==='navigate'){
    e.respondWith(fetch(r).then(res=>{if(res.ok){const cp=res.clone();caches.open(V).then(c=>c.put('./index.html',cp))}return res})
      .catch(()=>caches.match('./index.html').then(m=>m||caches.match('./'))));
    return}
  if(u.origin===location.origin||u.hostname==='fonts.googleapis.com'||u.hostname==='fonts.gstatic.com'){
    e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{if(res.ok||res.type==='opaque'){const cp=res.clone();caches.open(V).then(c=>c.put(r,cp))}return res})))}
});
