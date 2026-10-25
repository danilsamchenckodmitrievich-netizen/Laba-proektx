---
title: Карта index.html
date: 2026-10-25
tags: [code]
---

# Карта index.html

Номера строк примерные (на 2026-10-25) — искать по имени через `grep -n`.

| Строки | Что |
|---|---|
| 47–460 | CSS (header, home, lab, меню, работы) |
| 462–660 | совместимость `roundRect`, `readColors`, 3D-примитивы (шар, брусок, цилиндр, сосуд, призма) |
| 660–1800 | `LABS.push({...})` — 19 моделей: states, diffusion, motion, density, hooke, friction, resultant, solidp, gas, liquid, vessels, atm, press, archimedes, work, lever, pulleys, incline, energy |
| 1798–2550 | `WORKS` — 10 лабораторных: оборудование, предметы, движок перетаскивания, весы, мензурка, вариант ученика, работы 1–10 |
| 2551–2720 | график по таблице, мини-тест, цена деления/погрешность, `wCheckExtra` |
| 2723–2780 | `MTASKS` (39 задач к моделям), `mtHTML`, `mtCheck`, `GASP`, `MRHO` |
| 2781–2960 | APP: имя ученика, задание-ссылка (`setTask`, `taskNext`), `makeCode`/`readCode`, меню, язык, `home`, `worksHome`, `installHome`, `progressHome` |
| 2960–3130 | журнал на устройстве учителя (режим без сервера) |
| 3003 / 3042 | `openLab(id)` / `openWork(id)` |
| 3126–3240 | проверка работы: `wCheck` → `wGrade` (оценка 5/4/3/2) → `wVerdict`, `wLock`, `GRADES` |
| 3236–3345 | проектор, лупа, тема |
| 3349–3480 | сервер: `API` (адрес, ключ; переопределяется `window.LAB_API`), `rpc`, `ERRS`, `srvInit`, очередь отправки, пара (`PAIR`, `pairHTML`) |
| 3480–3790 | кабинет учителя: `TC`, `teacherHome`, `tcLoad`, ведомость (`tcSumHTML`), материалы (`tcMatHTML`), журнал (`tcJHTML`, `tcDetail`, `jrFlags`), администратор |
| 3789–3890 | просмотр учителя админом (`tcViewHTML`), обработчик кнопок `kAct` |
| 3892–4110 | тесты: ученик (`testHome`, `stMatsHTML`), учитель, конструктор, `TLIB` (8 готовых), `qFromSrv` |
| 4113–4165 | счётчик посещений `hitPage`, `route()` |

## Маршруты (`route`)

`#lab/<id>`, `#work/<id>`, `#task/<base64>`, `#test/<uuid>`, `#teacher`, `#install`, `#works`, `#progress`, иначе главная.

## Ключи localStorage (`lab-sirius-…`)

acc, device, queue (неотправленные результаты), grades, mtasks, journal, task, name, works, visited, filter, theme, backup, vid.

## Соглашения

- Кнопки кабинета: `data-k="…"` + `kAct`; кнопки работы: `data-act="…"`.
- Тексты ошибок сервера — в `ERRS`; новые коды ошибок добавлять туда и в `i18n/en.json`.
- Меню: ссылка с `href` ≠ `#` ведёт на свою страницу (исправление PR #19).

Related: [Сервер](server.md), [Проверка сайта локально](testing.md)
