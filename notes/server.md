---
title: Сервер
date: 2026-10-25
tags: [server, supabase]
---

# Сервер

- Supabase, проект `meloatifwjyulrzalnfm` (eu-north-1). Адрес и publishable-ключ — в `index.html`, строка `const API=`.
- Таблицы в схеме `lab` (RLS, снаружи закрыты). Сайт вызывает только `public.<функция>` через `POST /rest/v1/rpc/<функция>`.
- Функции — `security definer set search_path = ''`, всегда возвращают `jsonb`; ошибка — `{"err": "<код>"}`.
- Префиксы: `t_` учитель, `s_` ученик, `a_` администратор, `lab.` — внутренние; `ping` — для keepalive.
- Вход сделан на функциях (без Supabase Auth): `lab.teacher(token)`, `lab.sess(token)`, `lab.my_class(token, class)`.
- В конце каждого файла — `revoke … from public` + `grant execute … to anon, authenticated`.

## Файлы и порядок выполнения

schema → tests → stats → applications → accounts → observe → materials → progress → classinfo → backup → yearpair.

## Хранилище материалов

Bucket `materials` (публичный, 20 МБ, список MIME). Загрузка: `t_mat_file` создаёт запись `pending` → браузер `POST /storage/v1/object/materials/<path>` (заголовки `apikey`, `Content-Type`) → `t_mat_done`. Политики: insert — `mat_upload_ok(name)`, select/delete — `mat_remove_ok(name)` (статус deleted). Прямой DELETE из `storage.objects` запрещён триггером Supabase.

## Как менять сервер

1. Правка в `server/<файл>.sql` (файл = источник правды) + `apply_migration` в Supabase.
2. Несколько `DELETE` в одной миграции — отменяется/таймаут. Решение: по одной функции-помощнику на миграцию (`lab.del_teacher`, `lab.del_apps`, затем `lab.drop_teacher`) или флаг статуса вместо удаления.
3. Проверка на настоящей базе — `DO`-блок, который в конце делает `raise exception` (всё откатывается). Внутри `set local role anon` таблицы `lab.*` не читаются — считать до смены роли.
4. После изменения — обновить `server/README.md` (список файлов и порядок).

Related: [Карта index.html](code-map.md), [Проверка сайта локально](testing.md)
