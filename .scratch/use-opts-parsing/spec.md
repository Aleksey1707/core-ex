# Разбор опций `use`: режим по опции

Type: spec
Status: resolved

Решение и отвергнутые варианты — ADR-0085 (`docs/adr/0085-use-opts-parsing.md`). Решения, замеры и инвентарь —
`.scratch/use-opts-parsing/issues/`, `inventory.md`. Образец — ветка `prototype/use-opts-mode` (`1e1cd7d`,
удалена после влития).

## Problem Statement

Свод требует проверять опции `use` «на этапе компиляции», но не говорит, на каком именно. Builder'ы `lib/`
разошлись на шесть групп (`inventory.md`): 17 проверяют опции при раскрытии, 23 — в теле через `quote bind_quoted`,
4 смешанных, `DAO` особый. Отсюда:

- **ошибки в разное время**: опечатка в ключе у одного builder'а падает при раскрытии, у соседнего — при вычислении
  тела;
- **проходные функции ключей**: тело `bind_quoted` не видит атрибутов builder'а, поэтому десять builder'ов
  экспортируют `@doc false` `required_keys/0` / `optional_keys/0` только для себя, а у четырёх их не читает никто;
- **двойная проверка**: `Repo.Pg.StateStored` проверяет ключи `Repo.Pg`, затем вложенный `use Core.Repo.Pg` — ещё раз;
- **четыре формы префикса `CompileError`**, свои копии `where` / `reject!` / `fail!` в `Labels.*` и `View.Opts`, у
  части builder'ов метки нет;
- **тихий пропуск**: проверка по вложенному несобранному модулю через `exports?` молча даёт `false`.

Контракт при этом законно передаёт выражения: `name: first_line(@moduledoc)` у каждого Prim и Enum,
`tags: @tag_by_mod` у кодека событий, захваты `&Mod.fun/n`, вызовы функций из свода приложения.

## Solution

Режим разбора задаёт объявление опции (ADR-0085). Builder объявляет `@required_keys`, `@optional_keys`,
`@expression_keys`. Пролог `__using__` — `Helper.Opts.expand!` → `validate!` → `literal!`: ключи и опции-литералы
проверяются при раскрытии, опция-выражение уходит AST-ом в атрибут тела через валидатор `<key>!`.

- `quote bind_quoted` в `__using__` библиотеки не остаётся.
- Композиция — вложенный `use`, ключ проверяет тот, кто его отбрасывает.
- Проверка по другому модулю по умолчанию идёт при раскрытии, у опции с вложенным модулем — в теле. Отказ громкий
  везде.
- Тексты ошибок опций — `Helper.Opts.reject!/2` с одним префиксом.

Механически норму держит Credo-check `CredoChecks.UseOpts` на `lib/`. Он действует с первого среза, а
непереведённые модули перечислены в храповике `files: %{excluded: …}`.

## User Stories

1. As an автор кода на `Core.*`, I want получать опечатку в ключе любого `use` при раскрытии, so that ошибка
   приходила одинаково у всех builder'ов.
2. As an автор кода на `Core.*`, I want передавать выражения (`name: first_line(@moduledoc)`, `tags: @tag_by_mod`,
   захваты) там, где их разрешает контракт, so that переход не правил каждый Prim и кодек.
3. As an автор кода на `Core.*`, I want узнавать из `@moduledoc` builder'а, какие опции принимают выражение и чей
   модуль можно вложить в вызывающего, so that контракт был виден без чтения макроса.
4. As an автор кода на `Core.*`, I want получать `CompileError` «ожидается литерал» на атрибуте в опции-литерале, so
   that неописанное использование не проходило молча.
5. As an автор кода на `Core.*`, I want видеть ошибку опции в форме `<метка>: <ключ>: ожидается …, получено …` со
   строкой `use` в стеке, so that место и причина читались одинаково у всех builder'ов.
6. As an автор события, I want получать `CompileError` при вложенном несобранном `Payload`, а не тихий пропуск
   проверки `subject: :aggregate_id`, so that проверка не зависела от раскладки модулей.
7. As an автор `use Core.Repo.Pg.StateStored`, I want получать одну ошибку на неизвестный ключ, а не две, so that
   композиция не дублировала проверки.
8. As an автор builder'а библиотеки, I want общий пролог `expand!` / `literal!` и `reject!/2` в `Core.Helper.Opts`,
   so that разбор не копировался по модулям.
9. As an автор builder'а библиотеки, I want получать предупреждение `mix credo --strict` на `bind_quoted`, пролог мимо
   `expand!` и функции ключей, so that новый builder не возвращал старый режим.
10. As an ревьюер, I want видеть непереведённые builder'ы списком `excluded` храповика, so that расхождение свода и
    кода на время перевода было явным.

## Implementation Decisions

### `Core.Helper.Opts` (S1)

По образцу прототипа (`lib/core/helper/opts.ex` на ветке):

- `expand!(opts, caller, label) :: keyword()`: список опций должен быть литеральным keyword-AST, иначе `CompileError`
  «ожидается литеральный keyword, получено <`Macro.to_string`>». Значения раскрываются `Macro.expand_literals`, а
  сигилы `~w()a` / `~D[]` / `~U[]` — `Macro.expand`. Унарный минус над числом сворачивается в число, обход идёт
  в списки и пары.
- `literal!(opts, expression_keys, label) :: keyword()`: опции из `expression_keys` возвращаются AST, остальные
  должны пройти `Macro.quoted_literal?/1` и вычисляются `Code.eval_quoted`. Нелитерал — «<label>: <key>: ожидается
  литерал, получено <`Macro.to_string`>». В `quote` значения уходят через `Macro.escape/1`.
- Value-варианты примитивных проверок для `<key>!` в теле: `binary_value!(value, key, label)` и другие по нужде
  срезов. Каждый срез добавляет те, что нужны его builder'ам.
- `reject!(where, message) :: no_return()` — `raise CompileError, description: "#{where}: #{message}"`. Через него
  идут все `raise` самого `Helper.Opts`. Хвост «задано» меняется на «получено».
- `@moduledoc` — пролог, литерал, канал выражения, формат текстов.

### `CredoChecks.UseOpts` (S1)

В `scripts/credo_checks.exs`, по образцу `CredoChecks.FunctionExported`, включён в `.credo.exs` только для `lib/`.

- `quote` с `bind_quoted:` в любом модуле, где определён `defmacro __using__`, а не только в теле `__using__`.
- Если параметр `__using__(opts)` используется (не `_opts`), его первое употребление — аргумент
  `Core.Helper.Opts.expand!/3` или `Core.Prim.Opts.prepare!`. Пролог стоит в самом `__using__`.
- `def required_keys` / `optional_keys` / `expression_keys` в `lib/`, кроме `lib/core/prim/wrapper.ex`.
- `DAO` (`lib/core/dao.ex`) исключается `# credo:disable-for-next-line CredoChecks.UseOpts` с комментарием: открытый
  список уходит в `use Ecto.Repo`. В саму проверку исключение не вшивается.
- Храповик — `files: %{excluded: [...]}` проверки: файлы builder'ов срезов, кроме S1. Каждый срез вычёркивает свои,
  влитый последним удаляет список. Тест проверки — по образцу теста `FunctionExported`.

### S1 — пролог группы «раскрытие»

`Es.Aggregate`, `Es.Aggregate.Process`, `Es.Cmd`, `Core.Repo`, `Repo.Pg.Schema`, `View` (`View.Opts`) и шесть
case-модулей (`Enum.DocsCase`, `Es.EventCompatCase`, `Es.ProjectionCase`, `Es.Personal.KeyStoreCase`,
`Labels.CompletenessCase`, `Repo.ConstraintErrorsCase`).

- `Macro.expand_literals` → `expand!` + `validate!` + `literal!`. У `Core.Repo` отдельный `Macro.expand` для `only:`
  уходит в `expand!`.
- Тексты — через `reject!`. `View.Opts.where/2` (`", поле <name>"`) удаляется, путь идёт через `: `.
- Мёртвые `required_keys/0` / `optional_keys/0` у `Core.Repo` и `Repo.Pg.Schema` удаляются.
- Проверки по модулям (`module!`) остаются при раскрытии. Хуки `@before_compile` / `@after_compile` (`Es.Cmd`,
  `Es.Aggregate`, `Repo.Pg.Schema`) не трогаются.
- Контракт не ломается: значения этих builder'ов уже проверялись при раскрытии. Если `literal!` найдёт ранее
  принятый нелитерал, это строка накопительного пункта CHANGELOG.

### Prim

`Core.Prim`, `Prim.Wrapper`, семь обёрток (`Prim.String`, `.Integer`, `.Decimal`, `.UUID`, `.Date`, `.DateTime`,
`Prim.Compose`), `Prim.Opts`. Одним срезом, без переходного режима.

- `Prim.Opts.prepare!` — единый пролог семи обёрток при раскрытии: `expand!` → `validate!` → `literal!` → `kind!` →
  `validate_opts!` обёртки, без шага флагов. Инлайн-пролог прототипа в `Prim.String` не берётся.
- Протокол `Prim.Wrapper`: `required_keys/0` / `optional_keys/0` остаются, добавляется `expression_keys/0` (общие
  `name` / `mutate` / `validate` и свои: `re`, `max_len`, `namespace` …).
- Владение общими ключами:
  - `name`, `sensitive`, `personal` — у `Core.Prim`, обёртка отдаёт как есть, ошибка с меткой `Prim:`.
    `binary_value!(name)` в обёртке уходит;
  - `kind` — у обёртки (`validate_kind!` против `native_kind`);
  - `mutate` / `validate` — у обёртки, она переименовывает их в `custom_*`. Проверка `custom_*` у `Core.Prim`
    остаётся для прямых вызовов;
  - `sensitive` / `personal` у `Prim.Compose` — у самой `Prim.Compose` (наследование, запрет понижения).
- После среза `kind` / `sensitive` / `personal` у `Core.Prim` — литералы. Выражения: `name:`, `cast:` / `mutate:` /
  `validate:` / `custom_*`, `re:`, `max_len:`, `namespace:`.
- `value_type:` у `Core.Prim` и `of:` у `Prim.Compose`, которые сейчас читаются сырым AST при раскрытии, идут через
  общий пролог.
- `Prim.Opts.bad!/4` переходит на `reject!`.

### Labels

`Labels.Event` / `.ID` / `.Values` / `.Text` / `.Fields`, `Web.Event`.

- `bind_quoted` → пролог при раскрытии. Выражения: `Labels.Text` `with:`, `Labels.Fields` `fields:` / `value:`,
  `Web.Event` `user_ref:`.
- `required_keys/0` / `optional_keys/0` удаляются.
- Локальные `where/1`, `reject!` удаляются. Префикс `"<label> <Module>:"` меняется на `"<label>: <key>…"`. `fail!`
  хуков `@after_compile` с `file:` / `line:` не трогается.

### Тело-мелкие

`Enum`, `Context.Accessor`, `Es.ValueChanged`: `bind_quoted` → пролог, выражение — `Enum` `name:`. `values:`
(`~w()a`) — литерал. `required_keys/0` / `optional_keys/0` удаляются.

### Codec

`Codec`, `Codec.Facade`, `Codec.Plugin` (`Codec.Plugin.Opts`, `Codec.Plugin.Variants`, `Codec.Field`) и строка
`union: unquote(family)` вложенного `use` в `Es.Event.Codec`. Ждёт AW-2: там меняется вложенный `use`.

- Выражения: `Codec.Facade` `plugins:`, `Codec.Plugin` `types:`. `union:` — литерал, `Es.Event.Codec` передаёт
  модуль через `unquote`.
- `types:` / `fields:` / `variants:` `Codec.Plugin` — опции с вложенным модулем. Их форма проверяется при раскрытии
  (`literal!`), а проверки по модулям (`fields!` / `variants!`, struct, Prim) идут в теле через `<key>!` на
  `unquote(Macro.escape(lit))`.
- Генерация клауз по `fields:` / `variants:` — в месте `use`, вторым `quote unquote: false`, как в прототипе.
- Тексты `types:` / `union:` / `loadable:` получают метку `Codec.Plugin:`, тексты `Codec.Facade` — метку
  `Codec.Facade:`.
- `View.Dumper.codec_ast/3` (`types: [view]`) не меняется: литерал после `unquote`.

### Repo.Pg

`Repo.Pg`, `Repo.Pg.StateStored`, одним срезом. Ждёт AW-2 (`ensure_family_aggregate!` в обоих модулях).

- `Repo.Pg`: `bind_quoted` → пролог при раскрытии. Выражения: `query:`, `to_entity:` / `to_model:` / `to_view:` /
  `to_id:` / `default_filters:`. Тексты без метки получают `Repo.Pg:`. `required_keys/0` / `optional_keys/0`
  удаляются.
- `StateStored` при раскрытии проверяет свои ключи (`event_codec`, `outbox`, `children`) и обязательность усиленных
  (`to_entity`, `to_model`, `entity`, `id`). Остаток он отдаёт `use Core.Repo.Pg` как есть, неизвестные ключи и
  выражения остатка проверяет `Repo.Pg`. `own_keys/0` становится атрибутом.
- Проверка `exports: [domain: 3]` у `errors:` в `StateStored` уходит (это `validate_errors_module!` `Repo.Pg`),
  `ensure_version_mismatch!` и `ensure_aggregate_id!` остаются.
- Длинный `quote` `Repo.Pg` (`docs/rules/DEBT.md`) не трогается.

### Es-событие

`Es.Event`, `Es.Event.Payload`. Ждёт AW-2 и тикет-баг
`.scratch/es-event-nested-payload/issues/01-check-subject-silent-skip.md`.

- `payload:` — опция с вложенным модулем: форма проверяется при раскрытии, проверки по модулю (`check_subject!`,
  интроспекция `Payload`) — в теле через `<key>!`, с громким отказом.
- `Es.Event.Payload`: `bind_quoted` → пролог при раскрытии, `fields!/2` — валидатор тела.

### Es-кодек

`Es.Event.Codec`, `Es.Outbox`, `Es.Event.TagsCase`. Ждёт AW-2 и Codec.

- `Es.Event.Codec`: выражения — `tags:`, `upcasts:`. `type:` становится литералом. Валидаторы `tags!` / `upcasts!`
  остаются `<key>!`, `mods!` / `derive!` — по состоянию после AW-2. Мёртвые `required_keys/0` / `optional_keys/0`
  удаляются.
- `Es.Outbox`: мёртвые `required_keys/0` / `optional_keys/0` удаляются, пролог переходит на `expand!` / `literal!`.
- `Es.Event.TagsCase`: `except_tags:` / `except_types:` становятся литералами при раскрытии. `except_tags!/1` /
  `except_types!/1` остаются функциями проверки (их зовёт тест) или уходят — по коду.

### Es-репозиторий

`Es.Aggregate.Repo`, `Es.Aggregate.Repo.Pg`, `Es.KeyReservation`. Ждёт AW-3 и AW-4. Пролог переходит на `expand!` /
`literal!`, тексты — на `reject!`, `module!` остаётся при раскрытии. Контракт не ломается.

### Проекция

`Es.Projection`. Ждёт AW-5. `name:` / `events:` / `version:` / `personal:` становятся литералами при раскрытии,
`declaration!/4` разбирается на проверки при раскрытии. `repo:` / `codec:` — по состоянию после AW-5. Нелитерал —
строка накопительного пункта CHANGELOG.

### Порядок работ

`make` зелёный после каждого среза. Срез сам переводит свою часть `test/`, `fixtures/consumer`, `@moduledoc` и
дополняет пункт CHANGELOG. Нумерация AW — «Порядок работ» `.scratch/aggregate-wiring/spec.md`.

| Срез | Builder'ы | Ждёт |
|---|---|---|
| S1 — инструмент и «раскрытие» | `Helper.Opts`, `CredoChecks.UseOpts` с храповиком, `credo:disable` у `DAO`, пролог группы «раскрытие» вне AW | AW-1 |
| Prim | `Core.Prim`, `Prim.Wrapper`, семь обёрток, `Prim.Opts` | S1 |
| Labels | `Labels.*`, `Web.Event` | S1 |
| Тело-мелкие | `Enum`, `Context.Accessor`, `Es.ValueChanged` | S1 |
| Codec | `Codec`, `Codec.Facade`, `Codec.Plugin`; `union:` вложенного `use` в `Es.Event.Codec` | S1, AW-2 |
| Repo.Pg | `Repo.Pg`, `Repo.Pg.StateStored` | S1, AW-2 |
| Es-событие | `Es.Event`, `Es.Event.Payload` | S1, AW-2, тикет-баг `check_subject!` |
| Es-кодек | `Es.Event.Codec`, `Es.Outbox`, `Es.Event.TagsCase` | S1, AW-2, Codec |
| Es-репозиторий | `Es.Aggregate.Repo`, `Es.Aggregate.Repo.Pg`, `Es.KeyReservation` | S1, AW-3, AW-4 |
| Проекция | `Es.Projection` | S1, AW-5 |

- S1 идёт после AW-1: оба правят `lib/core/helper/opts.ex`.
- Срезы вне AW (Prim, Labels, Тело-мелкие) идут сразу после S1, параллельно, независимо от AW-2…5.
- Параллельные срезы конфликтуют только в списке `excluded` в `.credo.exs`: вливаемый вторым перестраивается на
  первый.

### Документация, свод, CHANGELOG

- **ADR** — ADR-0085 записан картой. ADR-0014 и ADR-0084 не уточняются.
- **Свод** — S1 тем же коммитом, что API и проверка, заменяет абзац «Параметры __using__ макроса…» в
  `docs/rules/20-agreements.md`, «Стиль кодирования» подразделом ниже; строки про `use` построчно и `~w()a` остаются.
  `docs/rules/12-errors.md` (строка про `Helper.Opts.validate!`) проверяется на совпадение. `make rules-check`.
  Другие срезы свод не правят: перечня опций по builder'ам в своде нет. Текст подраздела:

  ````markdown
  ### Опции `use`

  Builder — модуль с `defmacro __using__`. Его опции объявляются атрибутами `@required_keys`,
  `@optional_keys` и `@expression_keys`; режим разбора опции задаёт объявление, а не форма вызова
  (ADR-0085).

  - Пролог `__using__` MUST — `Core.Helper.Opts.expand!/3` → `validate!` → `literal!/3`: ключи и
    опции-литералы проверяются при раскрытии. Список опций MUST быть литеральным keyword-AST.
  - Опция-литерал — значение, для которого после `expand!/3` (алиасы, `__MODULE__`, сигилы
    `~w()a` / `~D[]` / `~U[]`, унарный минус) истинно `Macro.quoted_literal?/1`.
  - Опция-выражение (атрибут, вызов функции, захват `&Mod.fun/n`, `~r//`) MUST уходить AST-ом в
    атрибут тела через валидатор `<key>!`: публичный `@doc false` builder'а или value-вариант
    `Core.Helper.Opts`. Выражением опция объявляется, только если нелитерал разрешает контракт
    или он есть у реального вызова; `@moduledoc` builder'а MUST называть опции-выражения.
  - Опция-модуль (`repo:`, `codec:`, `errors:` …) MUST быть литералом.
  - Проверка по другому модулю SHOULD идти при раскрытии (`Core.Helper.Opts.module!`). У опции,
    чей модуль MAY быть вложен в вызывающего, — в теле через `<key>!` на
    `unquote(Macro.escape(value))`; `@moduledoc` называет такие опции. Проверка MUST падать на
    несобранном модуле (`Code.ensure_compiled/1` + `reject!`); `exports?` — только после неё.
  - Код, генерируемый по проверке в теле, MUST стоять в месте `use` вторым
    `quote unquote: false`, а не в `@before_compile`.
  - Builder, собранный из другого, MUST подключать его вложенным `use`. Ключ проверяет тот, кто
    его отбрасывает: отданный внутреннему как есть — внутренний, поглощённый или пересобранный —
    внешний. Читатель чужого ключа проверяет форму, без которой ключ не прочесть, и свои усиления.
  - Функции ключей (`required_keys/0`, `optional_keys/0`, `expression_keys/0`) builder MUST NOT
    экспортировать; исключение — протокол `Core.Prim.Wrapper`.
  - `quote bind_quoted:` в модуле с `__using__` — MUST NOT.

  Ошибка опции (при раскрытии и в `<key>!`) — `CompileError` через
  `Core.Helper.Opts.reject!(where, message)`; другие классы исключений MUST NOT.

  - Префикс — `<метка builder'а>: <ключ>[: <элемент>…]: <текст>`, без модуля вызывающего; при
    композиции — метка внутреннего builder'а.
  - `file:` / `line:` не передаются: строку `use` даёт стек.
  - Несовпадение формы или типа — `ожидается <что>, получено <значение>` (`inspect/1`, AST —
    `Macro.to_string/1`); смысловое нарушение — свободный текст.

  Проверки хуков `@before_compile` / `@after_compile` — о модуле, а не об опции: правило их не
  задевает.

  ```elixir
  # плохо — опции разбираются при вычислении тела, ключи — через проходные функции
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, Core.Enum.required_keys(), Core.Enum.optional_keys(), "Enum")
      @enum_name Keyword.fetch!(opts, :name)
    end
  end

  # хорошо — ключи и литералы при раскрытии, выражение — AST-ом в `<key>!`
  @required_keys ~w(name)a
  @optional_keys ~w(values codes)a
  @expression_keys ~w(name)a

  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, "Enum")
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, "Enum")
    opts = Helper.Opts.literal!(opts, @expression_keys, "Enum")

    quote do
      @enum_name Core.Helper.Opts.binary_value!(unquote(opts[:name]), :name, "Enum")
      @enum_values unquote(Core.Enum.values!(opts[:values], opts[:codes]))
    end
  end
  ```

  Проверяется: `mix credo --strict` (`CredoChecks.UseOpts`, только `lib/`) — `quote bind_quoted:`
  в модуле с `__using__`, первое употребление `opts` в `__using__` мимо `Helper.Opts.expand!/3` /
  `Prim.Opts.prepare!`, функции ключей вне `Core.Prim.Wrapper`.
  ````

- **`@moduledoc`** — каждый срез у своих builder'ов называет опции-выражения и опции, чей модуль MAY быть вложен в
  вызывающего: `Codec.Plugin` `types:` / `fields:` / `variants:`, `Es.Event` `payload:`. `@moduledoc`
  `StateStored` — «опции `Repo.Pg` плюс свои ключи».
- **CHANGELOG** — один накопительный пункт в «Не выпущено» → «Изменения контракта макросов». Его заводит первый
  вливаемый срез, который ломает контракт (Prim, Labels, Тело-мелкие, Codec, Repo.Pg, Es-событие, Es-кодек,
  Проекция). Каждый следующий дописывает свою строку таблицы. S1 и Es-репозиторий контракт не ломают. Итоговый
  текст:

  > - **Опции `use` — только литералом, кроме объявленных выражений** (решение — ADR-0085; норма —
  >   `docs/rules/20-agreements.md`, «Опции `use`»). Раньше часть builder'ов разбирала опции в теле модуля, и любая
  >   опция принимала атрибут или вызов функции (`values: @values` у `Enum`, `name: @name` у `Es.Projection`). Теперь
  >   ключи и опции-литералы проверяются при раскрытии `use`, а выражение принимают только опции, названные в
  >   `@moduledoc` builder'а. Атрибут или выражение в опции-литерале — `CompileError` «<метка>: <ключ>: ожидается
  >   литерал, получено …». Список опций выражением целиком — `CompileError` «ожидается литеральный keyword».
  >   Правка потребителя: атрибут или выражение → литерал в вызове; было `values: @values`, стало
  >   `values: ~w(a b)a`. Опции, принимающие выражение:
  >
  >   | Builder | Опции-выражения |
  >   |---|---|
  >   | `use Core.Prim` | `name:`, `cast:`, `mutate:`, `validate:`, `custom_mutate:`, `custom_validate:` |
  >   | `use Core.Prim.String` и другие обёртки | `name:`, `mutate:`, `validate:` и свои: `re:`, `max_len:`, `namespace:` |
  >   | `use Core.Enum` | `name:` |
  >   | `use Core.Codec.Facade` | `plugins:` |
  >   | `use Core.Codec.Plugin` | `types:` |
  >   | `use Core.Repo.Pg`, `use Core.Repo.Pg.StateStored` | `query:`, `to_entity:`, `to_model:`, `to_view:`, `to_id:`, `default_filters:` |
  >   | `use Core.Labels.Text` | `with:` |
  >   | `use Core.Labels.Fields` | `fields:`, `value:` |
  >   | `use Core.Web.Event` | `user_ref:` |
  >   | `use Core.Es.Event.Codec` | `tags:`, `upcasts:` |
  >
  >   Опции `use Core.Es.Projection` (`name:`, `events:`, `version:`, `personal:`) и `use Core.Es.Event.TagsCase`
  >   (`except_tags:`, `except_types:`) — только литералы.

  Тексты ошибок и удалённые `@doc false` функции ключей в CHANGELOG не идут.
- **«Версия библиотеки»** (`docs/rules/app/00-index.md`) — одна строка. Её добавляет первый ломающий срез тем же
  коммитом, что пункт CHANGELOG:

  | Устаревшая форма | Текущая |
  |---|---|
  | опция builder'а атрибутом или выражением (`values: @values`) | литерал в вызове; выражение — только у опций, названных в `@moduledoc` builder'а (`deps/core/docs/rules/20-agreements.md`, «Опции `use`») |

- **Глоссарий** — без записей: «опция-литерал» и «опция-выражение» — термины свода, а не домена.

## Testing Decisions

Хороший тест проверяет то, что видит автор кода на `Core.*`: какой `CompileError` он получил, когда (при раскрытии
или в теле) и с какой меткой. Устройство пролога не проверяется.

- **Тесты builder'а** в каждом срезе (`Code.compile_string` / `Code.eval_quoted`, как в существующих тестах опций):
  - опечатка в ключе — при раскрытии, с меткой;
  - нелитерал в опции-литерале — «ожидается литерал»;
  - неверное выражение (`name: @n` при `@n 1`) — в теле, с меткой;
  - у опций с вложенным модулем — вложенный модуль ниже `use` даёт громкий `CompileError` «модуль недоступен».
  Тесты, где список опций передаётся выражением целиком, переписываются.
- **`Helper.Opts`** (S1) — `expand!` (сигилы, унарный минус, список выражением), `literal!` (кортеж, struct, захват,
  атрибут), `reject!/2` — формат текста.
- **`CredoChecks.UseOpts`** (S1) — по образцу теста `FunctionExported`: `bind_quoted` в `defp` модуля с `__using__`,
  пролог мимо `expand!`, `_opts`, функции ключей вне `Prim.Wrapper`, `credo:disable`.
- **Es-событие** — тест тикета-бага на вложенный `Payload` с `subject: :aggregate_id` остаётся зелёным.
- **Приёмка каждого среза**:
  - `make` целиком;
  - `make consumer-check` без новых предупреждений фикстуры-потребителя (ADR-0014);
  - `mix xref graph --label compile` фикстуры не изменился, у библиотеки compile-рёбра только уходят;
  - храповик сужен на модули среза, а срез, влитый последним, удаляет список `excluded`;
  - тесты builder'а выше.

## Out of Scope

- Запрет опций-выражений ради единого режима «всё при раскрытии»: правит каждый Prim у каждого потребителя.
- Состав опций шести builder'ов aggregate-wiring — ADR-0084, `.scratch/aggregate-wiring/spec.md`.
- Длинный `quote` `Core.Repo.Pg` — `docs/rules/DEBT.md`.
- Тексты и позиция ошибок хуков `@before_compile` / `@after_compile`.
- `raise` мимо `reject!/2` как механическая проверка — ревью (ADR-0085, «Чем проверять»).
- Норма в ярусе `app/**`: у потребителя те же нормы `20-agreements.md` проверяет ревью, `credo_checks.exs` к нему не
  доставляется.
- Перевод кода потребителей.

## Further Notes

- Образец — ветка `prototype/use-opts-mode` (`1e1cd7d`, только локально, удалена после влития):
  `Helper.Opts` (`expand!/3`, `literal!/3`, `binary_value!/3`), `Core.Prim`, `Prim.String`, `Codec.Plugin`,
  `union:` в `Es.Event.Codec`. Скрипты текстов ошибок — `.scratch/use-opts-parsing/prototype/` на ветке. Это не
  источник истины: инлайн-пролог `Prim.String` и временные выражения `kind` / `sensitive` / `personal` у
  `Core.Prim` не переносятся. Ветка удаляется после среза Codec.
- Счёт builder'ов и групп — `inventory.md`, сверено на `7b25900`. После срезов AW состав опций Es-builder'ов другой:
  срез Es-* сверяется с кодом после своего AW-среза.
- Принятые отступления реализации от срезов выше (сверено на ревью интеграционной ветки):
  - `Helper.Opts.expand!/4` с четвёртым аргументом `refs`: опции-ссылки (`aggregate:` / `codec:` у
    `Es.Event.Family`) раскрываются в контексте функции — ребро xref остаётся runtime, граф
    `mix xref graph --label compile` фикстуры не меняется.
  - `StateStored` сохраняет `exports: [domain: 3]` у `errors:` (тикет 16): отказ идёт до вложенного `use Core.Repo.Pg`
    с меткой `Repo.Pg.StateStored:`, а не уходит в `Repo.Pg`.
  - Таблица накопительного пункта CHANGELOG по факту: у `use Core.Prim` — `value_type:` (без внутренних `type_opts:` /
    `pipeline_opts:`), у обёрток — `min:` / `max:` `Prim.Decimal`; литералы — `async:` у
    `Es.Personal.KeyStoreCase` и `fields:` у `Es.Event.Payload`.
  - Несобранный модуль: `Code.ensure_compiled/1` + `reject!` — `CompileError` «<метка>: <ключ>: модуль … недоступен»,
    а не `ArgumentError` из `Code.ensure_compiled!/1`; так же в своде.
