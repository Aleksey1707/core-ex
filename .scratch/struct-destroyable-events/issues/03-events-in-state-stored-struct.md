# 03: `events:` у state-stored агрегата

**What to build:** state-stored агрегат объявляется структурой по полям целиком: `use Core.Struct, events:
Family` порождает поле накопленных событий с типом по семейству и пустой коллекцией по умолчанию, а
репозиторий `Repo.Pg.StateStored` сверяет семейство со своим кодеком событий. Спека — `../spec.md`, решение —
ADR-0092.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `events:` — опция-модуль `use Core.Struct`, литерал; при раскрытии проверяется, что это семейство событий
      (`Core.Es.Event.Family`), иначе `CompileError`.
- [x] Порождается ключ `events` со значением `Es.Events.new()` (ключ при сборке `%S{}` необязателен) и
      `events: Core.Es.Events.t(Family.t())` в `@type t`.
- [x] Поле `events` в `fields:` рядом с `events:` — `CompileError`.
- [x] `events` не входит в `__struct_fields__/0`; семейство модуль отдаёт внутренней функцией (`@doc false`).
- [x] `Repo.Pg.StateStored`: `entity:`, собранный `Core.Struct` без `events:`, — `CompileError`; семейство
      `events:` не совпадает с семейством `event_codec:` — `CompileError`. Ручной `defstruct` не проверяется.
- [x] `Core.Es.Aggregate` и `Core.Es.Cmd`: `events:` у структуры по полям — `CompileError`.
- [x] `Core.StateStoredFixture.Entity` — на `use Core.Struct, events: …`; существующие тесты
      `Repo.Pg.StateStored` зелёные без правок.
- [x] Тесты: тип и значение по умолчанию — в `test/core/struct_test.exs` (`fetch_types/1`, `%S{}`); отказы
      `Core.Struct` — `Code.eval_quoted`; отказы ролей — в тестах `Repo.Pg.StateStored`, агрегата и команды через
      их `use`.
- [x] `@moduledoc` `Core.Struct` и `Repo.Pg.StateStored`; `docs/rules/11-domain.md` (структура по полям) и
      `docs/rules/13-repos.md` (state-stored агрегат): `events:` вместо ручного поля. `make rules-check` зелёный.
- [x] CHANGELOG, «Изменения контракта макросов»: `events:`, было → стало для ручного `defstruct` и `@type t`
      state-stored агрегата.
- [x] `make` зелёный.
