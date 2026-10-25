---
title: Проверка сайта локально
date: 2026-10-25
tags: [testing]
---

# Проверка сайта локально

Песочница не видит supabase.co и github.io, поэтому сайт проверяется с локальной копией сервера.

## Поднять (после каждого перезапуска контейнера)

```bash
D=/var/lib/postgresql/sirius; PG=/usr/lib/postgresql/16/bin
# первый раз: mkdir -p $D && chown postgres $D && su postgres -c "$PG/initdb -D $D/data -A trust"
su postgres -c "$PG/pg_ctl -D $D/data -o '-p 5433 -k $D' -l $D/pg.log start"
# первый раз: роли anon/authenticated, tools/dev/storage_stub.sql, затем server/*.sql по порядку из notes/server.md
psql_() { su postgres -c "psql -h $D -p 5433 -v ON_ERROR_STOP=1 -q $*"; }
(cd tools/dev && npm install --no-save pg@8 && nohup node shim.js > /tmp/shim.log 2>&1 &)   # порт 8766
mkdir -p /tmp/srv && cp -r index.html sw.js manifest.webmanifest icon-*.png en /tmp/srv/
sed 's#readColors();route();srvInit();#window.__t={S:()=>S,cur:()=>cur,T:()=>T,P:()=>P,mk:makeCode,rc:readCode,W:WORKS,acc:()=>ACC,srv:()=>SRV,tt:()=>TT,gr:()=>WGR,L:LABS,MT:MTASKS,TL:TLIB,TC:()=>TC};&#' index.html > /tmp/srv/test.html
(cd /tmp/srv && nohup python3 -m http.server 8765 &)
```

- `tools/dev/shim.js` — мини-PostgREST: `/rest/v1/rpc/<fn>` от имени `anon`, эмуляция хранилища, `/__down` и `/__up` — имитация обрыва сети.
- Остановить — по PID (`kill <pid>`), никогда `pkill -f` (убивает и чужое).

## Playwright

```js
const {chromium}=require('/opt/node22/lib/node_modules/playwright');
const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
const c=await b.newContext({viewport:{width:390,height:844}});
await c.addInitScript(()=>{window.LAB_API={url:'http://localhost:8766',key:'t'}});
```

Проверять 390 и 1000 px, RU и EN, светлую и тёмную темы; собирать `pageerror`.
Опубликованную версию показать можно: `git show origin/main:index.html > /tmp/srv/pub.html`.

Related: [Сервер](server.md), [Карта index.html](code-map.md)
