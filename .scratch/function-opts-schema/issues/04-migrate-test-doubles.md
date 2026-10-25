# 04: Перевод на схему — тестовые дублёры ES и outbox-репозиторий

**What to build:** опечатка в опциях тестовых дублёров и записи outbox падает `ArgumentError` с
именем функции, а не превращается в молчаливое умолчание, из-за которого тест потребителя проходит
не по тому сценарию.

Спека — «Объём перевода», волна 1.

**Blocked by:** 02

**Status:** resolved

- [x] Классифицированы и переведены `Es.Projection.Test.run_until_idle`,
      `Es.Aggregate.Test.given`, `Es.Personal.Test.key_destroyed`, `Outbox.Repo.Pg.append`; функция
      без схемы — с обоснованием в `## Comments`.
- [x] Ручные `Keyword.validate!` убраны; ручная проза об опциях в `@doc` убрана.
- [x] Тесты модулей: по одной проверке «неизвестный ключ → `ArgumentError`»; остальные зелёные.
- [x] CHANGELOG: переведённые публичные функции добавлены в список пункта «Ломающие изменения
      контракта».
- [x] `make` зелёный.

## Comments

- Свои ключи, схема: `Es.Aggregate.Test.given/3` и `Es.Personal.Test.key_destroyed/2` — `by:` и
  `at:` обязательны (`required: true`), `at:` — `{:struct, Core.Es.Event.At}`. `by:` — `:any`:
  проверку Prim делает тот, кто строит событие (`given` — кодек агрегата, `FunctionClauseError`;
  `key_destroyed` — guard `is_prim/1` в `Personal.key_destroyed/3`). Перевести `by:` на
  custom-валидатор Prim из тикета 07 — после его слияния (валидатор проверяет конкретный модуль, а
  здесь допустим любой UUID-Prim).
  Пропуск опции теперь `ArgumentError` вместо `KeyError` — в списке CHANGELOG.
- Без схемы, опции насквозь:
  - `Es.Projection.Test.run_until_idle/2` — `opts` целиком уходят в `Es.Projection.run_once/2`,
    у которой схема: опечатка падает `ArgumentError` с префиксом `run_once/2` (тест в
    `projection_test.exs`). Своя схема повторила бы чужую и разошлась бы с ней.
  - `Outbox.Repo.Pg.append/3` — `opts` целиком уходят в `insert_all` Ecto (`:prefix`, `:timeout`
    по `@callback` `Core.Outbox.Repo`); перечисление ключей Ecto — вне объёма спеки. Это ещё и
    обратный вызов behaviour (`@impl`).
