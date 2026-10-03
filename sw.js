/* Лаборатория Сириус: работа без интернета.
   Страница — сначала из сети (чтобы обновления приходили сразу), без сети — из кэша.
   Русская и английская версии кэшируются отдельно. Иконки, манифест и шрифты — из кэша. */
const V='lab-sirius-v2';
const CORE=['./','./index.html','./en/','./en/index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png','./apple-touch-icon.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const r=e.request;if(r.method!=='GET')return;
  const u=new URL(r.url);
  if(r.mode==='navigate'){
    const key=u.origin+u.pathname,en=/\/en\/(index\.html)?$/.test(u.pathname);
    e.respondWith(fetch(r).then(res=>{if(res.ok){const cp=res.clone();caches.open(V).then(c=>c.put(key,cp))}return res})
      .catch(()=>caches.match(key).then(m=>m||caches.match(en?'./en/index.html':'./index.html'))));
    return}
  if(u.origin===location.origin||u.hostname==='fonts.googleapis.com'||u.hostname==='fonts.gstatic.com'){
    e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{if(res.ok||res.type==='opaque'){const cp=res.clone();caches.open(V).then(c=>c.put(r,cp))}return res})))}
});
