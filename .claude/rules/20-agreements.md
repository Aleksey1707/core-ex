# Соглашения

Здесь описаны соглашения, правила и принципы, которые по возможности необходимо соблюдать при написании кода.

## Linters & Formatters

Запускай `make` для проверки корректности кода, сразу после внесения изменений. При обнаружении ошибок сразу их исправь.

`make` = `format-check → compile → deps-clean → xref → dialyzer → test → credo → security → audit`
(тот же порядок в `.pre-commit-config.yaml`):

| Шаг | Что проверяет |
|---|---|
| `format-check` | `mix format --check-formatted` — падает, а не правит |
| `compile` | `--warnings-as-errors`, включая нарушения `boundary` |
| `xref` | `mix xref graph --format cycles` — храповик на циклы компиляции |
| `credo` | `mix credo --strict` |
| `security` | `mix sobelow --skip --exit Low` |
| `audit` | `mix deps.audit` — известные CVE в зависимостях |

Физическая строка исходника ≤ 120 символов (Credo `Readability.MaxLineLength`). `mix format` строковые литералы не переносит — длинный `"..."` разбивать вручную (см. «Логирование»).

## Шапка модуля

Порядок частей: `@shortdoc` → `@moduledoc` → `@behaviour` → `import` → `alias` → `require`.
Проверяется `Credo.Check.Readability.StrictModuleLayout`.

Свободно расположены (в `ignore` проверки) — потому что их место диктует не стиль, а компилятор:

| Часть | Почему плавает |
|---|---|
| `use` | это DSL на алиасах (`use Repo.Pg.Schema, entity: Agg, id: Agg.ID`), а `use Repo.Pg.Schema` обязан идти **после** блока `schema` — иначе нет `defstruct` (`13-repos.md`) |
| module attribute | опции `use` часто ссылаются на атрибут (`use Es.Event.Codec, tags: @tag_by_mod`) |
| вложенный `defmodule` | Prim-модули объявляются внутри агрегата (`11-domain.md`) |
| `defstruct`, `@type` / `@typep` / `@opaque` / `@callback` | следуют за своим `use` / `schema` |

Следствия:

- `require Error` идёт **после** блока `alias` (иначе короткое имя ещё не объявлено);
- `import ... only:` — до `alias`, поэтому в `import` и `@behaviour` пишется **полный** путь
  модуля (`import Core.Version, only: [is_version: 1]`, `@behaviour Core.Validator`),
  а не короткое имя из алиаса, объявленного ниже;
- `alias` внутри группы — по алфавиту (`Credo.Check.Readability.AliasOrder`).

## Атомы из внешних данных

`String.to_atom/1`, `List.to_atom/1`, `Module.concat/1,2` на данных из HTTP, MQ или БД —
запрещены: таблица атомов не собирается сборщиком мусора, и произвольный ввод роняет VM.

- Разбор внешнего значения в атом — `String.to_existing_atom/1` либо `Enum.cast/1`
  (`Core.Enum` — закрытое множество).
- Compile-time вычисление имени модуля в макросе — допустимо, с `# credo:disable-for-...`
  и комментарием, почему `safe_concat` непригоден.

Проверяется `Credo.Check.Warning.UnsafeToAtom` (включён для `lib/`).

## Логирование (`Logger`)

| Уровень | Когда |
|---|---|
| `debug` | Штатный успешный путь: per-item и per-batch циклы (создание, отправка, актуализация, notify, enqueue, poller summary). Нужен для разбора, не для prod-потока (`:info` в prod). |
| `info` | Редкое: старт/стоп OTP, периодическая maintenance с ненулевым эффектом. |
| `warning` / `error` | Аномалии: провалы шага, retry, сбои persist, невалидный ввод на границе. |

Не логировать штатный per-item/per-batch на `info`. Тексты и наличие сообщений не убирать «для тишины» — понижать уровень. Phoenix request-логи (`Plug.Telemetry`) — вне этой политики.

Формат сообщения: `"<контекст>: key=#{value} …"` (как в usecases отправки / outbox).

Литерал `Logger.*` длиннее 120 символов — конкатенация `<>` по границе пробела перед следующим `key=`. Текст лога не менять. Не heredoc, не `\`-продолжение строки (`mix format` склеит в одну), не metadata вместо `key=`, не `# credo:disable-for-*` ради длины.

```elixir
Logger.debug(
  "сообщение создано: message_id=#{InCodec.dump(message.id)} kind=#{message.kind} " <>
    "integrator=#{Message.integrator(message)} owner_id=#{InCodec.dump(message.owner_id)}"
)
```

## Command-query separation (CQS)

По возможности следует соблюдать принцип разделения на команды и запросы: функция должна делать что-то одно:

- Либо читать данные и возвращать их (запрос)
- Либо изменять данные и ничего не возвращать (команда) — в Elixir: `:ok` / `{:ok, _}` только как сигнал успеха, не как «результат чтения»

Также требуется, чтобы из запроса вызывались лишь запросы. Команда может вызывать и команды, и запросы.
Таким образом по сигнатуре функции можно понять, что она выполняет и что от неё ожидать.

В usecases: команды → `:ok | {:error, _}` через `Helper.Transact.run(DAO, fn -> ... end)`; запросы → `{:ok, T} | {:error, _}` (см. `10-architecture.md`).

Внутри `Transact.run` допустимы только запросы через `DAO` и enqueue Oban. HTTP, publish в брокер,
кеш и `sleep` — MUST NOT: транзакция держит соединение и блокировки на всё время вызова.
Побочный эффект — после commit (`Helper.AfterCommit.register/1`) или отдельным шагом.
Таблица допустимого — «Что можно внутри `Transact.run`» в `10-architecture.md`.

В случае необходимости нарушить этот принцип необходимо дать имя функции, явно говорящее об этом (например `get_or_create_*`).

## Load/save агрегата — в одной функции

Чтение агрегата через репозиторий (`get` / `get!` / `get_by_*` / `find_many` / `list_*`) и его запись (`insert` / `update` / `save` / `delete`) MUST находиться в теле одной функции — вместе с `Transact.run`, охватывающим обе операции.

- Мутации домена, разбор результата чтения и логирование выносить в чистые helper'ы без repo-вызовов.
- Batch: пачку перечитывает та же функция, которая сохраняет (`find_many` + `Result.traverse(list, &@repo.save(&1, context))`); верхний уровень передаёт вниз идентификаторы, а не загруженные агрегаты.
- Чтение без последующей записи (query-usecases, history, чтение соседнего агрегата — например `UserRoles` при проверке доступа) правилом не ограничено.

```elixir
# плохо — load в одной функции, save в другой
defp load(owner_id, version, context) do
  with {:ok, current} <- @repo.get_by_owner_id(owner_id, context),
       do: @repo.get(current.id, version, context)
end

# хорошо — получить → обработать → сохранить в одном теле
Transact.run(DAO, fn ->
  with {:ok, settings} <- @repo.get_by_owner_id(owner_id, version, context),
       {:ok, settings} <- apply_attrs(settings, owner_id, attrs),
       {:ok, _saved} <- @repo.save(settings, context) do
    :ok
  end
end)

# batch — та же функция перечитывает пачку и сохраняет её
Transact.run(DAO, fn ->
  with {:ok, entities} <- @repo.find_many(pairs(ids), context),
       {:ok, mutated} <- Result.traverse(entities, mutate),
       {:ok, _saved} <- Result.traverse(mutated, &@repo.save(&1, context)) do
    :ok
  end
end)
```

Резолв alternate key (`owner_id` → агрегат) отдельным чтением перед `get(id, version)` — тот же
разнос load/save, только внутри чтения: два SELECT ради одной проверки `version`. Кастомный
`get_by_*` в write-репозитории MUST принимать `version` (`%Version{} | :current`) и проверять её
сам — как `get/3` (`Repo.Pg.version_error/4`).

Почему: `Repo.Sc` фиксирует эталон по первому чтению, а `Version` проверяется на записи. Разнесённые load/save дают запись по устаревшей копии, немой пропуск `update` (`Sc.fetch(context, Entity, id) == entity`) и невидимую в одном месте границу транзакции.

## Context — последний аргумент

У функций, принимающих `%Context{}`, context MUST быть последним параметром.

Исключение — модули, основная цель которых — работа с контекстом (`Context.Accessor` и производные вроде `CurrentUser`; также `Repo.Sc`).

## Наименование запросов: `find` / `get` / `get!`

| Имя | Возврат | Исключения |
|---|---|---|
| `find` | `T \| nil` | Допускаются, но по возможности избегать |
| `get` | `{:ok, T} \| {:error, reason}` | Не поднимать; ошибка — в `{:error, _}` |
| `get!` | `T` | При отсутствии/ошибке — `raise` |

Контракты repo-методов (`get`/`get!`/`list`/`page`/…) — см. `13-repos.md`.

```elixir
@spec find(Prim.t() | nil) :: term() | nil

def find(nil), do: nil
def find(%Prim{value: value}), do: value

@spec get(Prim.t() | nil) :: {:ok, term()} | {:error, Error.t()}

def get(prim) do
  case find(prim) do
    nil -> {:error, Error.domain(__MODULE__, :no_value, prim, message: "Значение не найдено")}
    value -> {:ok, value}
  end
end

@spec get!(Prim.t() | nil) :: term()

def get!(prim) do
  case get(prim) do
    {:ok, value} -> value
    {:error, error} -> raise Exc, error
  end
end
```

## Паттерн-матчинг и арность

- По возможности всегда проверять тип/форму аргументов через pattern matching в заголовке функции (или `case`/`with`), а не через `is_*` / `if` без необходимости.
- Составные общие guards — в `Core.Guard`; подключать через `import` (не `alias`). Не оборачивать тривиальные Kernel `is_*`.
  - Prim / struct: `is/2`, `is_opt/2` (`defguard`); обязательный Prim в head по умолчанию — `%Mod{}`.
  - Enum: `is_enum/2`, `in_enum/3` (макросы; subset сразу в `when`, без `@attr`; enum-модуль подтягивается через `ensure_compiled`).
  - Пример: `when is(id, User.ID) and is_opt(at, CreatedAt) and is_enum(status, Status)`.
- Доменные guards типа вне Guard — у источника типа (например `Version.is_version/1` для `t() | :current`).

## Документация

У каждого публичного модуля и публичной функции должны быть `@moduledoc` / `@doc`.

`Core.Enum` — строже: в `@moduledoc` MUST быть таблица с описанием **каждого** значения
(`11-domain.md`, «Описание значений в `@moduledoc`»). Проверяется тестом, а не ревью.

## Спецификации типов

Каждая публичная функция обязана иметь `@spec`. По возможности избегать использование `any()` / чрезмерно широкого `term()`.

Роль `@spec`: в первую очередь документация сигнатуры, во вторую — Dialyzer. Домен допустимых аргументов на этапе компиляции задают **clauses** / `when` (см. «Домен функции…»), не `@spec`.

Исключение — функции, которые генерирует макрос внутри `quote` под `@impl true`
(`Core.Repo.Pg`, `Core.Repo.Pg.Es`, `Core.Es.Event.Repo.Pg`): источник типов там —
`@callback` соответствующего behaviour, а `@spec` пришлось бы собирать `unquote`-ом
из опций `use`. Обычный (не генерируемый) модуль с `@impl` от этого не освобождён —
`@spec` пишется как везде.

Визуально: после блока `@doc`/`@spec` — пустая строка, затем `def`/`defp` (или `@impl` + `def`). `@doc` и `@spec` без пустой строки между собой. `@impl` остаётся рядом с функцией (разрыв между `@spec` и `@impl`). Правило едино для одно- и многострочных спек.

```elixir
@doc "…"
@spec name(...) :: ...

def name(...) when ... do
  ...
end

@spec foo(...) :: ...

@impl true
def foo(...) do
  ...
end
```

## Домен функции и инференс типов (Elixir 1.20+)

Система типов Elixir выводит допустимый домен аргументов из **clauses** (pattern matching / guards). Лишняя clause, которая принимает «невалидный» вход и делает `raise`, расширяет домен и **скрывает** ошибку от компилятора: вызов выглядит допустимым.

Длинный заголовок `def` / `when` допустим и предпочтителен перед упрощением ради короткой `@spec`.

Правила:

- Не добавлять catch-all / defensive-clauses «на всякий случай» с `raise ArgumentError` (и аналогами), если по контракту аргумент недопустим. Пусть неверный вызов даст `FunctionClauseError` на runtime, а при известном типе — предупреждение на compile time.
- Допустимый ввод описывать clauses и `@spec`/`@type`; недопустимый — **не** перечислять в заголовках функции.
- Исключение: явная обработка доменной/прикладной ошибки через `{:error, _}` или документированный `raise` на границе (`get!` / `unwrap!` при ожидаемом error-варианте контракта), а не «подстраховка» от неверного типа входа.

```elixir
# плохо — недопустимый вход в домене; инференс не ругается на вызов
def parse(:invalid, _opts), do: raise ArgumentError, "invalid"
def parse({:ok, data}, opts), do: do_parse(data, opts)

# хорошо — домен только допустимых форм; иное → FunctionClauseError / type warning
def parse({:ok, data}, opts), do: do_parse(data, opts)
```

## Сборка struct

При конструировании с полями даты и пользователя (`created_at`, `created_by`, `at`, `by`, ...) всегда указывать их последними. Сначала дата, затем пользователь (`at`, `by`). Если требуется несколько таких пар — порядок: создание, обновление, удаление, т.е. `created_at`, `created_by`, `updated_at`, `updated_by`, `deleted_at`, `deleted_by`.

## Алиасы модулей

Алиасить родительский модуль пространства имён, а не лист с `as:`. Вызов — через родителя: `Parent.Leaf.fun(...)`.

```elixir
# плохо
alias Core.Helper.Keyword, as: OptKeyword
OptKeyword.check_opts!(...)

# хорошо
alias Core.Helper
Helper.Keyword.check_opts!(...)
```

То же для `Prim` (`Prim.String`, …) и `Validator` (`Validator.String`, …), `Repo` (`Repo.Pg`, `Repo.Sc`). Детали repo-слоёв — `13-repos.md`.

Репозиторий агрегата (`<Aggregate>.Repo`, `13-repos.md`) MUST адресоваться через алиас
**агрегата** — `alias MyApp.Domain.<BC>.Common.Delivery` → `Delivery.Repo.Pg.Schema`. Отдельный
`alias …Common.Delivery.Repo` — **MUST NOT**: короткое имя `Repo` в том же файле почти всегда
занято `Core.Repo` (`use Repo.Pg`), и такой алиас молча его перебивает.

Листовые модули без вложенности (`Error`, `Exc`, `Context`) — алиасить напрямую, без `as:`.

Исключение — профили Codec:

```elixir
alias MyApp.Codec.Internal, as: InCodec
alias MyApp.Codec.External, as: OutCodec
```

`InCodec`/`OutCodec` — entity-фасады (Prim + plugins). Явный Prim-only: `alias MyApp.Codec.Prim.Internal, as: PrimInCodec`.

Кастомные Prim `dump/1` / `dump_kind/2` / `load_kind/3` — с `@impl true` (`@behaviour Core.Codec`). Entity-плагины — `Core.Codec.Plugin` (dump-only: `loadable: false`; для `tagged: true` — обязательные уникальные `tags:`); фасад — `use Core.Codec.Facade`.

### Dump/load только через фасад

Entity-кодек (`use Core.Codec.Plugin`) MUST быть в `Codec.plugins()`. Вложенные сущности и соседние типы — **только** через фасад, не через модуль чужого плагина.

Внутри плагина — аргумент `codec` (`dump/2`, `load/3`) и хелперы `load_optional/3`, `load_many/3`. Снаружи плагина — `InCodec` / `OutCodec`.

```elixir
# плохо
Step.Codec.dump(step, codec)
Content.Codec.load(Content.Sms, raw, codec)
Step.Codec.dump(step, InCodec)

# хорошо
codec.dump(step)
codec.load(Step, raw)
load_many(Step, list, codec)
InCodec.dump(step)
```

Исключение: реконструкция события — `<Aggregate>.Event.Codec.load_event!/8` (dump-only плагин, см. `11-domain.md`). Не вводить обходные `load_for_channel` / обёртки, которые зовут соседний `*.Codec` в обход фасада.

При коллизии короткого имени (например `<BC>.Repo` и `Core.Repo` в одном файле) — полный путь или `as:` только для одного из конфликтующих; правило про родителя при этом не отменяется.

## Правило понижения

Требуется придерживаться правила понижения.

**Правило понижения** — организация кода, при которой модуль читается как последовательный рассказ сверху вниз. За каждой функцией следуют функции следующего уровня абстракции; читатель последовательно спускается по уровням абстракции.

Основные характеристики:

- Код читается как хорошо написанная газетная статья
- Сначала — высокоуровневые концепции и алгоритмы
- Степень детализации увеличивается к концу файла
- В конце — функции и подробности низшего уровня
- Взаимозависимые функции — в нисходящем порядке (вызываемая ниже вызывающей)

Так проще понять структуру модуля по начальным функциям, не погружаясь сразу в детали реализации.

## Разделители внутри модуля

Модуль, разбитый на смысловые блоки, размечается комментарием `# ===== <блок> =====`
(`aggregate`, `domain ops`, `factory`, `private`, …) — по одному на каждый блок.

Если такого деления нет, MUST как минимум отделять публичные функции от приватных строкой
`# ---` — в точке перехода от `def` / `defmacro` / `defguard` / `defdelegate` к
`defp` / `defmacrop` / `defguardp`.

- разделитель окружён пустыми строками, отступ — как у определений модуля;
- ставится **на каждом** переходе public → private: по правилу понижения приватный хелпер
  стоит сразу под своим публичным вызывающим, и таких переходов в модуле может быть
  несколько — каждый читается как «ниже детали реализации того, что выше»;
- ставится перед `@doc` / `@spec` приватной функции, а не между спекой и `defp`;
- модуль без публичных функций (например `<Aggregate>.Event.Codec`, где публичный API
  генерирует макрос) разделителя не требует — отделять нечего; то же для тест-модулей,
  где приватные хелперы идут после `test`-блоков;
- вложенный `defmodule` размечается самостоятельно; в код внутри `quote` разделитель
  не ставится — он принадлежит модулю, куда инжектится.

```elixir
def send(%Message.ID{} = id, %Context{} = context), do: send_many([id], context)

# ---

defp send_groups(groups, by, context) do
```

## Стиль кодирования

В `use` каждый передаваемый параметр обязан быть на отдельной строке.
Список атомов должен описываться через ~w(...)a

Параметры __using__ макроса должны делиться на обязательные и опциональные, оформляться в виде атрибутов модуля и выполняться проверка переданных параметров и их значений на этапе компиляции.

### Оформление `if`

Keyword-форма — когда **обе** ветки однострочные:

```elixir
# хорошо
if condition,
  do: :ok,
  else: {:error, reason}

# плохо — однострочные ветки, но do/else-блок
if condition do
  :ok
else
  {:error, reason}
end
```

Для ветки только `do` — тоже keyword: `if condition, do: ...`.

Если хотя бы одна ветка многострочная — keyword-форма не применяется: `mix format` всё равно
развернёт её в блок, а читаемость падает. Тогда либо do/else-блок, либо (предпочтительно)
`case` / `cond` / отдельные clause с pattern matching.

### Safe vs bang

В application-flow с контрактом `:ok | {:error, _}` / `{:ok, T} | {:error, _}` предпочитать safe API (`get`, `new`, `from_events`, …), а не bang.

Bang (`get!`, `new!`, `raise Exc`, …) — только на явных bang-границах. Исключения: Schema bang-mappers (`to_entity!` / `to_model!`) на call site своих строк / persist валидного domain; реконструкция `*.Event.load_event!` (как bang `to_entity!` для event store); Specs/ACL `CurrentUser.get!`; compile-time константы (`Namespace.new!` в module attribute и т.п.); OTP/config init.

Schema mappers: dual API — safe `to_entity`/`to_model` (Result) и bang `to_entity!`/`to_model!` (`raise Exc`). Dirty/infra (Outbox reserve) → safe; `use Repo.Pg` / write-path → bang. Детали — `13-repos.md`.

Event store: bang (`to_entity!` / `load_event!`) — только на write-path. **Read-path истории
(`list_by_aggregate` / `page_by_aggregate`, HTTP GET) MUST быть safe**: строки в event store
живут вечно, и одно событие с типом, который кодек больше не знает, обязано дать доменную
ошибку `:unknown_event_type`, а не 500 на всю страницу истории.

Конверсия datetime-Prim в domain flow (мутации агрегатов / actor-domain): только `from` + `with` (`CreatedAt.from`, `UpdatedAt.from`, `Es.Event.At.from`, …), не `from!` и без обёрток вроде `event_at/1` — на call site сразу `Es.Event.At.from(at)`.

Текущее время в Result-flow: `now` + `with` (`CreatedAt.now()`, …); bang-границы / OTP / тесты — `now!`.

Repo Specs / ACL-фильтры, которым по контракту **обязан** быть current user в `Context` (например `CurrentUser.get!/1` в `only_own` / `approver?`): отсутствие ID — ошибка программиста; bang допустим.

### Использование try

Если тело try больше одной строки - вынести в отдельную приватную функцию.

При работе с ресурсами использовать конструкцию try after для гарантированного закрытия/очистки, при условии, что нет более специализированного решения.
