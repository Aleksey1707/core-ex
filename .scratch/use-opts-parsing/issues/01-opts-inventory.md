# 01: Опции `use` сейчас

Type: task
Status: resolved

Blocked by: None

## Question

Как сейчас разбираются опции каждого модуля `lib/` с `__using__`? Нужна таблица, по строке на builder:

- режим: при раскрытии (`Macro.expand_literals` + `Core.Helper.Opts.validate!/4`), в теле (`quote bind_quoted`),
  смешанный (ключи при раскрытии, часть значений AST-ом в тело — `Es.Event.Codec`, `Projection`, `Outbox`);
- по опции: литерал или выражение после `Macro.expand_literals` у реальных вызовов (`fixtures/consumer`,
  `test/support`, вложенные `use` библиотеки); где проверяются ключ и значение;
- вложенные `use` библиотеки и что они передают (`use Core.Codec.Plugin, types: Map.keys(@es_tag_by_mod)`,
  `use Core.Repo.Pg, unquote(pg_opts)`);
- `required_keys/0` / `optional_keys/0` (`@doc false`): кто зовёт снаружи, кроме собственного тела;
- тексты `CompileError`: свои `where` / `reject!` / `fail!` и формат префикса (`label`, модуль, поле);
- двойная проверка ключей `Repo.Pg.StateStored` → `Repo.Pg`: какие ключи проверяются дважды и где.

Итог — таблица в `## Answer` (или файл рядом, со ссылкой) и короткий список групп builder'ов с одинаковым разбором.

## Answer

Таблица, вложенные `use`, тексты `CompileError` и двойная проверка `StateStored` → `Repo.Pg` — в
[`inventory.md`](../inventory.md). Группы builder'ов с одинаковым разбором:

1. **Раскрытие целиком** (17): `Es.Aggregate`, `Es.Aggregate.Process`, `Es.Aggregate.Repo`, `Es.Aggregate.Repo.Pg`,
   `Es.Cmd`, `Es.Event`, `Es.KeyReservation`, `Es.Outbox`, `Repo`, `Repo.Pg.Schema`, `View`, шесть case-модулей.
   После тикета 14 сюда ушли `Es.Event`, `Repo`, `Es.Outbox`: список ревью устарел.
2. **Смешанный** (4): `Es.Event.Codec` (`tags:` / `type:` / `upcasts:` в тело), `Es.Projection` (`name:` /
   `events:` / `version:` / `personal:`), `Es.Event.TagsCase` (`except_tags:` / `except_types:`),
   `Repo.Pg.StateStored` (свои ключи при раскрытии, значения `Repo.Pg` — в его тело через вложенный `use`).
3. **Тело, ключи из функций builder'а** (10): `Enum`, `Context.Accessor`, `Es.ValueChanged`, пять `Labels.*`,
   `Web.Event`, `Repo.Pg`.
4. **Тело, ключи литералом в вызове** (4): `Codec`, `Codec.Facade`, `Codec.Plugin`, `Es.Event.Payload`.
5. **Prim** (9): `Prim`, `Prim.Wrapper` и семь обёрток через `Prim.Opts.prepare!/2`; ключи — функции,
   сгенерированные `Prim.Wrapper`; вложенный `use Core.Prim` получает выражения над переменной тела.
6. **Особый**: `DAO` — только `require!` по сырому AST, опции уходят в `use Ecto.Repo`.

Факты, которые ждут тикеты 02–05:

- Нелитеральные значения у реальных вызовов: атрибут (`tags: @tag_by_mod`, `upcasts: @upcasts`,
  `max_len: @max_len`), вызов функции (`name: first_line(@moduledoc)`, `plugins: <App>.Codec.plugins()`,
  `namespace: Mod.namespace()`, `query: Schema.base_query()`), захват `&Mod.fun/n` (`cast:` / `mutate:` /
  `validate:` Prim, `to_entity:` / `to_model:` / `default_filters:` `Repo.Pg`, `with:` `Labels.Text`, вложенные
  `text:` / `dump:`), сигил (`~w()a`, `~r//`, `~D[]` / `~U[]`). `plugins:` и `namespace:` вызовом функции — контракт
  свода приложения (`app/11-domain.md`, `app/13-repos.md`).
- `Es.Projection` передаёт `name:` / `events:` AST-ом в тело, хотя у всех 29 вызовов они литеральны.
- Ключи литеральны у всех вызовов; список опций выражением целиком бывает только у вложенных `use` библиотеки
  (`unquote(pg_opts)`, `use_prim`) и в тестах.
- `required_keys/0` / `optional_keys/0`: у `Es.Event.Codec`, `Es.Outbox`, `Repo`, `Repo.Pg.Schema` их никто не зовёт;
  у десяти builder'ов группы 3 их зовёт только своё тело; снаружи — `StateStored` (`Repo.Pg`) и `Prim.Opts`
  (функции, сгенерированные `Prim.Wrapper`).
- Префикс `CompileError` бывает четырёх форм, у `Repo.Pg` и части `Codec.*` метки нет; `file:` / `line:` — только в
  хуках `@before_compile` / `@after_compile`.
