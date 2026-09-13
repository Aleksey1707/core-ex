# 30: Контракт event-sourced агрегата: `Core.Es.Cmd`, `Core.Es.Aggregate`, given / then без БД

**What to build:** автор домена пишет event-sourced агрегат: команды `<Aggregate>.Cmd.<Name>` с `use Core.Es.Cmd`,
`decide/2` и `evolve/2` под `use Core.Es.Aggregate, event_codec:` — и тестирует решения без БД через
`Core.Es.Aggregate.Test.given/3`. Библиотека генерирует свёртку и чистый шаг `execute/2` и ставит событиям id, версии,
`by` и `at`. Все случаи контракта видны на синтетическом `Core.EsFixture.Account`.

**Blocked by:** [25: Апкаст событий](25-event-upcasts.md), [29: `Core.Es.EventCompatCase`](29-event-compat-case.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Контракт event-sourced агрегата»,
[прототип](../prototype/es-aggregate-contract/README.md)

- [ ] `use Core.Es.Cmd`: `by` (Prim автора событий агрегата) и `at` (`%Es.Event.At{}`) обязательны в `@enforce_keys`,
      иначе `CompileError`; интроспекция команды.
- [ ] `use Core.Es.Aggregate, event_codec:`: без `id` / `version` в `defstruct` — `CompileError`; `decide/2` /
      `evolve/2` — через `@behaviour`.
- [ ] Генерируются `fold/2` (свёртка от любого состояния; разрыв версий или чужой `aggregate_id` — `raise`), `fold/3`
      (состояние + команда + результат `decide`), `execute/2` → `{:ok, {[Es.Event], состояние}} | {:error, _}`,
      `__es_event_codec__/0`.
- [ ] Результат `decide` — `{:ok, [{Event.Mod, payload} | Event.Mod]} | {:error, Error.t()}`; библиотека проставляет
      `id` события, `aggregate_id` из состояния, `aggregate_version` по порядку от `state.version` (от `nil` — с 1),
      `by` / `at` из команды; модуль не из `__es_mods__/0` кодека отвергается guard'ом; `{:ok, []}` — без событий и
      без роста версии; `id` / `version` состояния ведёт только библиотека.
- [ ] `Core.Es.Aggregate.Test.given(state, results, by:, at:)` → состояние; `by:` / `at:` обязательны без значений по
      умолчанию; ExUnit не используется.
- [ ] `use Core.Es.EventCompatCase, aggregate:` — кодек из `__es_event_codec__/0` и полнота `evolve`:
      `evolve(%Agg{id: aggregate_id}, событие)` на фикстуре каждого тега; провал — только `FunctionClauseError`
      самой `Agg.evolve/2`; проверка вызывается на сломанном агрегате без клаузы.
- [ ] `Core.EsFixture.Account` в `test/support`: ошибки `decide` (`not_found` / `already_exists` по `version: nil`),
      `{:ok, []}`, два события на команду через `fold/3`, событие без нагрузки, апкаст v1 → v2 → v3, удалённый тип (тег
      в `tags:`, клауза `evolve` возвращает состояние как есть); кодек с `type:`; golden-фикстуры;
      `use Core.Es.EventCompatCase, aggregate:` на нём.
- [ ] Тесты `decide` через `given` и then в короткой форме (`{:ok, [{Mod, payload}]}`, `{:ok, []}`,
      `{:error, %Error{kind: :domain, code: …}}`), `async: true`, без БД; тесты `evolve` через `fold`.
- [ ] `11-domain.md`, «Aggregates»: общее + H3 «State-stored», «Event-sourced» (`evolve` чистый, голова MUST матчить
      только событие, «Проверяется: `use Core.Es.EventCompatCase, aggregate:`», `not_found` / `already_exists` —
      ошибки `decide`, плохо / хорошо), «Команда». `19-testing.md` — H2 «Event-sourced агрегат». `description` skill
      `domain`. `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
