# Лаборатория Сириус — памятка для Claude

Сайт по физике 7 класса: https://danilsamchenckodmitrievich-netizen.github.io/Laba-proektx/
(GitHub Pages публикует ветку `main`). Подробные заметки — [notes/INDEX.md](notes/INDEX.md); читать по нужде, не целиком.

## Пользователь

- Отвечать по-русски, просто, **без кода** в ответах. Пользователь не программист.
- Порядок работы: коммит → push в рабочую ветку → PR в `main` → merge (пользователь так делает всегда, отдельно не спрашивать).
- Перед коммитом: `python3 tools/build_en.py` — должно быть «Без перевода: 0».

## Где что лежит

| Что | Где |
|---|---|
| Весь сайт (≈4200 строк, Canvas 2D) | `index.html` — карта: [notes/code-map.md](notes/code-map.md) |
| Английская версия | `en/index.html` собирается из `index.html` + `i18n/en.json` ([notes/workflow.md](notes/workflow.md)) |
| Сервер (Supabase, SQL) | `server/*.sql` — правила: [notes/server.md](notes/server.md) |
| Офлайн | `sw.js` (видео/аудио не кэшируются) |
| Ежедневная проверка сервера | `.github/workflows/keepalive.yml` |
| Локальная проверка сайта с сервером | `tools/dev/` — [notes/testing.md](notes/testing.md) |
| Презентация, документы, ролики | [notes/artifacts.md](notes/artifacts.md) |
| История решений | [notes/history.md](notes/history.md) |

## Главные ловушки

- Supabase-ключ (`sb_publishable_…`) передаётся **только** в заголовке `apikey`, никогда в `Authorization`.
- Миграция с несколькими `DELETE` на Supabase отменяется — одна команда на функцию или флаги статуса.
- Контейнер не видит supabase.co и github.io: сервер проверять через инструменты Supabase, сайт — локально.
- После перезапуска контейнера локальные серверы (Postgres 5433, shim 8766, http 8765) надо поднимать заново; убивать только по PID, не `pkill -f`.
- Не трогать удалённое: страница `#forteachers` убрана по просьбе пользователя.
