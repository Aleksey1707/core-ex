# 07: `Projection.await/3` вместо `Core.Es.Projection.await/4`

**What to build:** автор usecase ждёт проекцию вызовом `Projection.await(Agg, %Agg.ID{} = id, timeout)` у модуля своей
проекции. Агрегат, чьих событий нет в `events:`, ID другого агрегата и невозможная clause по результату ловятся при
сборке. Исходы (`:ok`, `:projection_timeout`, `:projection_rebuilding`), ошибки программиста, span, telemetry и режим
`:inline` прежние.

**Blocked by:** 01

**Status:** ready-for-agent

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Ожидание проекции — `Core.Es.Projection`»

- [ ] `use Core.Es.Projection` генерирует `await/3`: clause на каждый агрегат, чьи события есть в `events:`, голова —
      закрытый struct его ID, результат сужен до `:ok | {:error, %Core.Error{}}` в `generated: true`.
- [ ] `Core.Es.Projection.await/4` — `@doc false` реализация; вызовы в core-ex переведены.
- [ ] Фикстура: маркеры G4 (ID другого агрегата), G4b (агрегат не из `events:`), G4c (невозможная clause). Ожидание
      проекции на события двух агрегатов в usecase — ноль предупреждений.
- [ ] Тесты ожидания проекции — на `await/3`; исходы, `ArgumentError` внутри транзакции, `RuntimeError` без дерева,
      `:inline`, span и telemetry — прежние.
- [ ] Свод: `22-projections.md`, `20-agreements.md` (CQS и `Transact.run`), `12-errors.md`, `17-otp-concurrency.md`,
      `21-observability.md`; ярус `app/`: `15-web-api.md`, `19-testing.md`, `00-index.md` (строка карты
      «`Core.Es.Projection.await/4` → `Projection.await/3`»); `README.md`; описание скилла `projections`.
- [ ] moduledoc `Core.Es.Projection` («Ожидание», генерируемая функция).
- [ ] `CHANGELOG.md`, «Не выпущено»: пункт «Read-after-write» дополнен, «было → стало».
- [ ] `make` зелёный.
