# 30: Контракт event-sourced агрегата: `Core.Es.Cmd`, `Core.Es.Aggregate`, given / then без БД

**What to build:** автор домена пишет event-sourced агрегат: команды `<Aggregate>.Cmd.<Name>` с `use Core.Es.Cmd`,
`decide/2` и `evolve/2` под `use Core.Es.Aggregate, event_codec:` — и тестирует решения без БД через
`Core.Es.Aggregate.Test.given/3`. Библиотека генерирует свёртку и чистый шаг `execute/2` и ставит событиям id, версии,
`by` и `at`. Все случаи контракта видны на синтетическом `Core.EsFixture.Account`.

**Blocked by:** [25: Апкаст событий](25-event-upcasts.md), [29: `Core.Es.EventCompatCase`](29-event-compat-case.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Контракт event-sourced агрегата»,
[прототип](../prototype/es-aggregate-contract/README.md)

- [x] `use Core.Es.Cmd`: `by` (Prim автора событий агрегата) и `at` (`%Es.Event.At{}`) обязательны в `@enforce_keys`,
      иначе `CompileError`; интроспекция команды.
- [x] `use Core.Es.Aggregate, event_codec:`: без `id` / `version` в `defstruct` — `CompileError`; `decide/2` /
      `evolve/2` — через `@behaviour`.
- [x] Генерируются `fold/2` (свёртка от любого состояния; разрыв версий или чужой `aggregate_id` — `raise`), `fold/3`
      (состояние + команда + результат `decide`), `execute/2` → `{:ok, {[Es.Event], состояние}} | {:error, _}`,
      `__es_event_codec__/0`.
- [x] Результат `decide` — `{:ok, [{Event.Mod, payload} | Event.Mod]} | {:error, Error.t()}`; библиотека проставляет
      `id` события, `aggregate_id` из состояния, `aggregate_version` по порядку от `state.version` (от `nil` — с 1),
      `by` / `at` из команды; модуль не из `__es_mods__/0` кодека отвергается guard'ом; `{:ok, []}` — без событий и
      без роста версии; `id` / `version` состояния ведёт только библиотека.
- [x] `Core.Es.Aggregate.Test.given(state, results, by:, at:)` → состояние; `by:` / `at:` обязательны без значений по
      умолчанию; ExUnit не используется.
- [x] `use Core.Es.EventCompatCase, aggregate:` — кодек из `__es_event_codec__/0` и полнота `evolve`:
      `evolve(%Agg{id: aggregate_id}, событие)` на фикстуре каждого тега; провал — только `FunctionClauseError`
      самой `Agg.evolve/2`; проверка вызывается на сломанном агрегате без клаузы.
- [x] `Core.EsFixture.Account` в `test/support`: ошибки `decide` (`not_found` / `already_exists` по `version: nil`),
      `{:ok, []}`, два события на команду через `fold/3`, событие без нагрузки, апкаст v1 → v2 → v3, удалённый тип (тег
      в `tags:`, клауза `evolve` возвращает состояние как есть); кодек с `type:`; golden-фикстуры;
      `use Core.Es.EventCompatCase, aggregate:` на нём.
- [x] Тесты `decide` через `given` и then в короткой форме (`{:ok, [{Mod, payload}]}`, `{:ok, []}`,
      `{:error, %Error{kind: :domain, code: …}}`), `async: true`, без БД; тесты `evolve` через `fold`.
- [x] `11-domain.md`, «Aggregates»: общее + H3 «State-stored», «Event-sourced» (`evolve` чистый, голова MUST матчить
      только событие, «Проверяется: `use Core.Es.EventCompatCase, aggregate:`», `not_found` / `already_exists` —
      ошибки `decide`, плохо / хорошо), «Команда». `19-testing.md` — H2 «Event-sourced агрегат». `description` skill
      `domain`. `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - поля `defstruct` на разворачивании `use` ещё неизвестны, поэтому `id` / `version` агрегата и `by` / `at` в
    `@enforce_keys` команды проверяются в `@after_compile` по `__info__(:struct)`;
  - кодек `event_codec:` на компиляции не загружается (проверка — атом), guard модуля события — `is_map_key` по карте
    из `__es_mods__/0` в рантайме: иначе цикл компиляции агрегат → кодек → события → `Agg.ID`;
  - интроспекция команды — маркер `__es_cmd__/0`; нарушения свёртки — `ArgumentError`, как ошибки программиста
    `Core.Es.Store.append`;
  - фикстура разнесена по файлам `test/support/es_fixture/` (агрегат, события, кодек, ошибки): `%Event.Opened{}` в
    `evolve` не может ждать модуль, объявленный ниже в том же файле;
  - сломанный агрегат — `Core.EsFixture.BrokenAccount`: без клаузы `Closed`, а `KeyError` в теле `Renamed` и
    `FunctionClauseError` приватной функции у `Frozen` провалом полноты не считаются;
  - сверх пунктов тикета по спеке («Своды»): `14-events-outbox.md`, «Golden-фикстуры» — строка про полноту `evolve`;
    `description` skill `testing`.
