# Опции `use` сейчас — инвентаризация

Ответ тикета «Опции `use` сейчас» (`issues/01-opts-inventory.md`). Сверено с кодом `develop` на 2026-10-24
(`7b25900`). Литеральность значений — по всем вызовам `use Core.*` в `lib/`, `test/`, `fixtures/consumer/`:
значение считается литералом, если после подстановки алиасов и `__MODULE__` (то, что делает
`Macro.expand_literals`) оно `Macro.quoted_literal?/1`.

## Режимы

- **раскрытие** — `Macro.expand_literals` + `Core.Helper.Opts.validate!/4` в теле макроса, значения проверены
  до `quote`;
- **тело** — `quote bind_quoted`, ключи и значения проверяются при вычислении тела модуля;
- **смешанный** — ключи и часть значений при раскрытии, остальные значения AST-ом в тело, там их проверяет
  публичный `@doc false` валидатор builder'а.

## Таблица

| Builder | Режим | Ключи: где | Значения: где | Нелитералы у реальных вызовов | `required_keys/0` / `optional_keys/0` |
|---|---|---|---|---|---|
| `Es.Aggregate` | раскрытие | раскрытие | раскрытие (`event_codec:` — `atom!`) | — | нет |
| `Es.Aggregate.Process` | раскрытие | раскрытие | раскрытие (`repo:` — `module!`) | — | нет |
| `Es.Aggregate.Repo` | раскрытие | раскрытие | раскрытие | — | нет |
| `Es.Aggregate.Repo.Pg` | раскрытие | раскрытие | раскрытие (`key_reservations:`, `snapshot:` тоже) | — | нет |
| `Es.Cmd` | раскрытие | раскрытие (ключей нет) | — | — | нет |
| `Es.Event` | раскрытие | раскрытие | раскрытие | — | нет |
| `Es.KeyReservation` | раскрытие | раскрытие | раскрытие | — | нет |
| `Es.Outbox` | раскрытие | раскрытие | раскрытие | — | есть, **никто не зовёт** |
| `Repo` | раскрытие | раскрытие | раскрытие; `only:` — отдельно `Macro.expand` (`~w()a` — сигил) | `only: ~w(...)a` | есть, **никто не зовёт** |
| `Repo.Pg.Schema` | раскрытие | раскрытие | раскрытие | — | есть, **никто не зовёт** |
| `View` | раскрытие | раскрытие | раскрытие (`View.Opts`) | — | нет |
| `Enum.DocsCase`, `Es.EventCompatCase`, `Es.ProjectionCase`, `Es.Personal.KeyStoreCase`, `Labels.CompletenessCase`, `Repo.ConstraintErrorsCase` | раскрытие | раскрытие | раскрытие | — | нет |
| `Es.Event.Codec` | смешанный | раскрытие | `event:` — раскрытие; `tags:` / `type:` / `upcasts:` — тело (`type!/2`, `tags!/1`, `upcasts!/2`; производные `mods!/1`, `derive!/2`) | `tags: @tag_by_mod` (11 вызовов, в т. ч. фикстура-потребитель), `upcasts: @upcasts` (фикстура-потребитель) | есть, **никто не зовёт** |
| `Es.Projection` | смешанный | раскрытие | `repo:` / `codec:` — раскрытие; `name:` / `events:` / `version:` / `personal:` — тело (`declaration!/4`) | **нет**: все 29 вызовов литеральны | нет |
| `Es.Event.TagsCase` | смешанный | раскрытие | `otp_app:` / `async:` — раскрытие; `except_tags:` / `except_types:` — тело (`except_tags!/1`, `except_types!/1`, их зовёт и тест) | нет (`except_types:` литерал, `except_tags:` не используется) | нет |
| `Repo.Pg.StateStored` | смешанный | раскрытие (ключи `Repo.Pg` + свои) | свои (`event_codec`, `outbox`, `children`, `id`, `entity`, `errors`) — раскрытие; остальное уходит `use Core.Repo.Pg, unquote(pg_opts)` и проверяется в теле `Repo.Pg` | `query: Schema.base_query()`, `to_entity:` / `to_model:` / `to_id:` — захваты | нет (своё `own_keys/0`, никто снаружи не зовёт) |
| `Repo.Pg` | тело | тело | тело | `query: from(...)`; `to_entity:` / `to_model:` / `to_view:` / `default_filters:` — захваты | есть: своё тело и `StateStored` |
| `Codec` | тело | тело (литералы списков в вызове `validate!`) | тело | — | нет |
| `Codec.Facade` | тело | тело | тело | `plugins: <App>.Codec.plugins()` (фикстура-потребитель, `test/support`; контракт — `docs/rules/app/11-domain.md`) | нет |
| `Codec.Plugin` | тело | тело | тело | вложенные: `types: Map.keys(@es_tag_by_mod)`, `union: @es_event` (из `Es.Event.Codec`) | нет |
| `Enum` | тело | тело | тело | `name: first_line(@moduledoc)`, `values: ~w(...)a` (17 из 20) | есть: своё тело |
| `Context.Accessor` | тело | тело | тело | — | есть: своё тело |
| `Es.ValueChanged` | тело | тело | тело | — | есть: своё тело |
| `Es.Event.Payload` | тело | тело | тело (`fields!/2`) | — | нет |
| `Labels.Event`, `Labels.ID`, `Labels.Values` | тело | тело | тело (`declaration!` / `declare!` / `labels!`) | — | есть: своё тело |
| `Labels.Text` | тело | тело | тело (`Check.capture!`) | `with: &Mod.fun/1` (все 6) | есть: своё тело |
| `Labels.Fields` | тело | тело | тело (`declare!/2`) | `fields:` / `value:` с вложенными захватами `text: &Mod.fun/1` | есть: своё тело |
| `Web.Event` | тело | тело | тело (`user_dump!/3`, `labels!/2`) | `user_ref: [dump: &Mod.fun/2, schema: …]` | есть: своё тело |
| `Prim` | тело (+ `value_type:` снимается с AST при раскрытии) | тело | тело | `name: first_line(@moduledoc)`, `cast:` / `mutate:` / `validate:` — захваты; вложенный из `Prim.Wrapper.use_prim` — выражения над переменной тела `base` | нет |
| `Prim.Wrapper` (только библиотека) | тело | тело | тело | `required:` / `optional:` — `~w()a` | генерирует их в каждой обёртке; зовёт `Prim.Opts.prepare!/2` |
| `Prim.String`, `.Integer`, `.Decimal`, `.UUID`, `.Date`, `.DateTime` | тело (`Prim.Opts.prepare!/2`) | тело | тело (`validate_opts!/1` обёртки) | `name: first_line(@moduledoc)`; `re: ~r/…/`; `after:` / `before: ~D[…]` / `~U[…]`; `max_len: @max_len`; `namespace: Mod.namespace()` (фикстура-потребитель; контракт — `docs/rules/app/13-repos.md`); `mutate:` / `validate:` — захваты | через `Prim.Wrapper` |
| `Prim.Compose` | тело (+ `of:` читается сырым AST при раскрытии, без проверки) | тело | тело | — | через `Prim.Wrapper` |
| `DAO` | особый: `Opts.require!/3` по сырому AST при раскрытии, список открыт | раскрытие (только обязательные) | не проверяются: опции уходят в `use Ecto.Repo` | — | нет |

## Вложенные `use` библиотеки

| Откуда | Что | Что передаёт |
|---|---|---|
| `Es.Event.Codec` | `use Core.Codec.Plugin` | `types: Map.keys(@es_tag_by_mod), union: @es_event` — выражение и атрибут тела |
| `View` (`View.Dumper.codec_ast/3`) | `use Core.Codec.Plugin` во вложенном `Codec` | `types: [unquote(view)], loadable: false` — литерал после `unquote` |
| `Repo.Pg.StateStored` | `use Core.Repo.Pg` | `unquote(pg_opts)` — сырой AST опций вызывающего без своих ключей |
| `Prim.*` (`Prim.Wrapper.use_prim/3`) | `use Core.Prim` | `name: Keyword.fetch!(base, :name)` и т. п. над переменной тела, `cast: &…`, `validate: {Validator.String, type_opts}` — не литералы; `value_type:` снимается `Core.Prim` с AST до тела |
| `Prim.String` и др. (модули библиотеки) | `use Core.Prim.Wrapper` | `label:`, `native_kind:`, `required:` / `optional: ~w()a` |
| `DAO` | `use Ecto.Repo` | `unquote(opts)` целиком |
| case-модули | `use ExUnit.Case` | `async:` — значение, проверенное при раскрытии |

## Тексты `CompileError`

Свои хелперы:

- `where/1` → `"<label> <Module>"`: `Labels.Event`, `Labels.Fields`, `Labels.ID`, `Labels.Text`; та же строка
  инлайном — `Labels.Values`, `Web.Event`. `View.Opts.where/2` → `"View: <label>, поле <name>"`.
- `reject!/2` (без `file:` / `line:`): `Labels.Fields` (по строке `where`), `Labels.ID` (по модулю).
- `fail!/2` (с `file:` / `line:` из `env`, в `@after_compile`): `Labels.Event`, `Labels.Fields`.
- `Prim.Opts.bad!/4` → `"<label>: <key>: ожидается …, получено: …"` — общий для обёрток Prim.

Формы префикса:

| Форма | Где |
|---|---|
| `"<label>: …"` | `Helper.Opts`, `Prim.Opts`, почти все builder'ы раскрытия, `Enum`, `Es.ValueChanged`, `Codec.Facade` (`module!`) |
| `"<label> <Module>: …"` | `Labels.*`, `Web.Event`, часть `Codec.Plugin.Opts` (`variants:` / `fields:`) |
| `"<label>: <Module> …"` | хуки `@before_compile` / `@after_compile`: `Es.Projection`, `Repo.Pg.Schema` |
| без метки | `Repo.Pg` (`errors: …`, `constraint_errors: …`, `to_entity/to_view: …`), `Repo.expand_only/1` («неизвестный вид репозитория»), `Codec.Facade` («плагин …», «тип … объявлен дважды»), `Codec.Plugin.Opts` (`types: …`), `Es.Event.Codec` («тип агрегата … объявлен дважды») |

`file:` / `line:` ставятся только в хуках `@before_compile` / `@after_compile` (`Es.Cmd`, `Es.Aggregate`,
`Es.Projection`, `Es.Event.Codec`, `Repo.Pg.Schema`, `Labels.Event` / `Labels.Fields` через `fail!`,
`Codec.Plugin.Opts`); при раскрытии и в теле `use` — нигде.

## Двойная проверка `Repo.Pg.StateStored` → `Repo.Pg`

`StateStored` проверяет при раскрытии `Repo.Pg.required_keys() ++ ~w(to_entity to_model event_codec outbox entity
id)a` и `Repo.Pg.optional_keys() ++ ~w(children)a`, затем отбрасывает `@own_keys` (`event_codec outbox children`) и
отдаёт остаток в `use Core.Repo.Pg`. Дважды проверяются:

- обязательность `schema` / `behaviour` / `errors`;
- неизвестные ключи по всему остатку (один и тот же список `Repo.Pg.optional_keys()`);
- значение `errors:` — экспорт `domain/3` (`StateStored` через `module!`, `Repo.Pg` через
  `validate_errors_module!/1`).

`StateStored` строже: `to_entity`, `to_model`, `entity`, `id` у него обязательны, у `Repo.Pg` — опциональны. Сам
список опций он требует литеральным keyword («ожидается литеральный keyword opts»), значения — нет: они уходят в
тело `Repo.Pg`.
