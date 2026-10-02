# 04: Usecase ждёт проекцию по `wait:`

**What to build:** изменяющий usecase event-sourced агрегата принимает `wait: :none | pos_integer()`, после commit
ждёт проекцию литеральным `Projection.await/3` и возвращает `{:projected, view}` или `{:accepted, id, version}`.
`MyAppWeb.Accepted` переводит `Prefer` в `wait:` и результат — в 200 или 202, без колбэка ожидания. Ответы API не
меняются; воркер и подписчик получают ожидание тем же вызовом.

**Blocked by:** 01

**Status:** ready-for-agent

**Spec:** [Контекст — граница Boundary, раскладка — вертикаль по агрегату](../spec.md) — «`wait:`»

- [ ] `rules/22`, «Read-after-write»: MUST NOT ожидания в usecase снят; ожидание — после commit, вне транзакции,
      литеральным вызовом с ID, суженным до `%Agg.ID{}`
- [ ] `rules/20`, «Разделение изменения и чтения»: исключение «изменяющий usecase с `wait:` MAY вернуть представление»
- [ ] `app/10`, «Usecases»: возвраты команды и создания при `wait:`; `:projection_timeout` и
      `:projection_rebuilding` → `:accepted`; создание отдаёт `{id, version}` в обоих случаях
- [ ] `app/15`, «Ожидание проекции»: экшен передаёт `wait:`, `MyAppWeb.Accepted` без колбэка; схемы ответов и
      `Preference-Applied` прежние
- [ ] `app/19`: тест ветки `:accepted` — тест usecase через `Core.Es.Projection.Test.with_rebuilding/2`
- [ ] фикстура: usecase с `wait:` и сценарий на неверный агрегат или ID в его `await` (prior art —
      `scenarios/await.ex`)
- [ ] ADR вместо ADR-0030 в части «usecase не ждёт» и формы хелпера; в ADR-0030 — пометка о замене
- [ ] `CONTEXT.md`: «Usecase», «Ожидание проекции»
- [ ] `app/00`, таблица устаревших форм: колбэк в `MyAppWeb.Accepted` → `wait:`
- [ ] CHANGELOG, «Ломающие изменения контракта»: `MyAppWeb.Accepted` и сигнатуры команд, «было → стало»
- [ ] `make` зелёный
