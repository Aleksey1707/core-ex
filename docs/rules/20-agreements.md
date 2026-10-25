# Соглашения

- **Область.** Весь код библиотеки и потребителя: оформление модуля, именование, `@spec` / `@doc`,
  guards, алиасы, логирование, стиль.
- **Читать перед.** Любой правкой кода — это базовый файл свода; отдельно — перед новым модулем,
  публичной функцией, логом, алиасом и выбором safe / bang.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

Правила действуют на весь код; сила каждого задана его модальностью.

## Linters & Formatters

Запускай `make` для проверки корректности кода, сразу после внесения изменений. При обнаружении
ошибок сразу их исправь.

Состав пайплайна: в библиотеке — `CLAUDE.md`, «Команды»; у потребителя —
`deps/core/docs/rules/app/20-agreements.md`, «Пайплайн проверок».

Физическая строка исходника ≤ 120 символов (Credo `Readability.MaxLineLength`). `mix format`
строковые литералы не переносит — длинный `"..."` разбивать вручную (см. «Логирование»).

## Шапка модуля

Порядок частей: `@shortdoc` → `@moduledoc` → `@behaviour` → `import` → `alias` → `require`.
Проверяется `Credo.Check.Readability.StrictModuleLayout`.

Свободно расположены (в `ignore` проверки) — потому что их место диктует не стиль, а компилятор:

| Часть | Почему плавает |
|---|---|
| `use` | это DSL на алиасах (`use Repo.Pg.Schema, entity: Agg, id: Agg.ID`), а `use Repo.Pg.Schema` обязан идти **после** блока `schema` — иначе нет `defstruct` (`13-repos.md`) |
| module attribute | опции `use` часто ссылаются на атрибут (`use Es.Event.Codec, tags: @tag_by_mod`) |
| вложенный `defmodule` | Prim-модуль MAY объявляться внутри агрегата (`11-domain.md`) |
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

## Экспорт модуля

В коде библиотеки (`lib/`, `test/`) экспорт модуля проверяется `Core.Helper.Module.exports?/3`.
`function_exported?/3` и `:erlang.function_exported/3` — MUST NOT, в том числе за
`Code.ensure_loaded?/1`.

Почему: обе отвечают только про загруженный код. Mix в dev и test грузит модули лениво, и ещё не
загруженный модуль для них пуст: проверка молча его пропускает, а итог зависит от порядка тестов.
В релизе модули загружены на старте, и там ошибки не видно. `exports?/3` модуль грузит, а при
сборке ждёт его компиляции, поэтому один вызов верен и в макросе, и в рантайме. Отдельной формы
для «модуль уже загружен» нет: различать два случая на ревью и есть то, что не срабатывало.

```elixir
# плохо — не загруженный модуль выпадает из сверки
for module <- modules, function_exported?(module, :__es_type__, 0), do: module

# хорошо
for module <- modules, Helper.Module.exports?(module, :__es_type__, 0), do: module
```

Проверяется: `mix credo --strict` (`CredoChecks.FunctionExported`, `scripts/credo_checks.exs`).

## Логирование (`Logger`)

| Уровень | Когда |
|---|---|
| `debug` | Штатный успешный путь: per-item и per-batch циклы (создание, отправка, актуализация, notify, enqueue, poller summary). Нужен для разбора, не для prod-потока (`:info` в prod). |
| `info` | Редкое: старт/стоп OTP, периодическая maintenance с ненулевым эффектом. |
| `warning` / `error` | Аномалии: провалы шага, retry, сбои persist, невалидный ввод на границе. |

Не логировать штатный per-item/per-batch на `info`. Тексты и наличие сообщений не убирать «для
тишины» — понижать уровень. Phoenix request-логи (`Plug.Telemetry`) — вне этой политики.

Повтор команды после отказа записи (`Core.Es.Transact`) — штатная конкурентная запись, а не
аномалия: `debug` на каждый повтор; исчерпание предела повторов — `warning`.

Проверяется: `test/core/es/transact_test.exs`; через процесс агрегата —
`test/core/es/aggregate/process_test.exs`, describe «повтор после отказа записи».

Формат сообщения: `"<контекст>: key=#{value} …"`.

Литерал `Logger.*` длиннее 120 символов — конкатенация `<>` по границе пробела перед следующим
`key=`. Текст лога не менять. Не heredoc, не `\`-продолжение строки (`mix format` склеит в одну), не
metadata вместо `key=`, не `# credo:disable-for-*` ради длины.

```elixir
Logger.debug(
  "агрегат создан: id=#{InCodec.dump(aggregate.id)} kind=#{aggregate.kind} " <>
    "owner_id=#{InCodec.dump(aggregate.owner_id)} created_by=#{InCodec.dump(aggregate.created_by)}"
)
```

`IO.puts` вместо `Logger` — MUST NOT: вывод мимо `Logger` теряет уровень, metadata и
`trace_id`. Вывод точки входа оператора (mix-таска) — не лог, а ответ оператору:
`Mix.shell().info/1`. Задача релиза (`MyAppApp.Release.*`, `bin/my_app eval`) Mix не видит: её
ответ оператору — `IO.puts`, исключение `Credo` — на её файлы.

Проверяется: `mix credo --strict` (`Credo.Check.Refactor.IoPuts`, исключён `test/`).

## Разделение изменения и чтения (CQS)

Изменение и чтение разделяются: функция SHOULD делать что-то одно:

- Либо читать данные и возвращать их (читающая функция)
- Либо изменять данные и ничего не возвращать (изменяющая функция) — в Elixir: `:ok` / `{:ok, _}`
  только как сигнал успеха, не как «результат чтения»

Также требуется, чтобы из читающей функции вызывались лишь читающие. Изменяющая функция может
вызывать и изменяющие, и читающие. Таким образом по сигнатуре функции можно понять, что она
выполняет и что от неё ожидать.

Возвраты usecases — `deps/core/docs/rules/app/10-architecture.md`, «Usecases».

Внутри `Transact.run` допустимы только запросы через `DAO`, постановка фоновой задачи и уничтожение
ключа субъекта `Core.Es.Personal.destroy_key/3` (`23-personal-data.md`). HTTP, publish в брокер,
кеш, `sleep`, ожидание проекции `Projection.await/3` и команда процесса агрегата
`Agg.Process.execute` — MUST NOT: незакоммиченную запись проекция не увидит вовсе, а команда идёт
своей транзакцией, и откат её попытки отменил бы внешнюю. Таблица допустимого, её обоснование и
куда выносить побочный эффект — `deps/core/docs/rules/app/10-architecture.md`, «Что можно внутри
`Transact.run`».

Проверяется для ожидания проекции и команды процесса агрегата: `ArgumentError` в
`Projection.await/3` и `Agg.Process.execute` внутри транзакции.

Изменяющая функция не возвращает **состояние**, но MAY вернуть **результат собственного
выполнения** — информацию, порождённую самой записью и недоступную иначе:

- `Repo` `insert`/`update`/`save` → `{:ok, entity}`: агрегат в состоянии после записи (у агрегата
  с событиями — с очищенными `events`), то есть значение, от которого мутируют дальше;
- `Repo.Pg.insert_many/4` → число записанных строк: при `on_conflict: :nothing` это единственный
  сигнал о пропущенных дублях;
- команда usecase → версия агрегата после записи (у event-sourced агрегата — вместе с его id,
  `{:accepted, id, version}`), команда-создание → идентификатор созданного агрегата
  (`deps/core/docs/rules/app/10-architecture.md`, «Usecases»).

Изменяющий usecase event-sourced агрегата с `wait:` MAY вернуть представление read-модели —
`{:projected, view}`, прочитанное после commit, вне транзакции записи: проекция в `exports`
контекста не входит, и дождаться её, чтобы прочитать запись, может только сам usecase. Особого
имени такой usecase не требует: исключение задано здесь, а возврат представления виден по тегу
`:projected` (`22-projections.md`, «Read-after-write»;
`deps/core/docs/rules/app/10-architecture.md`, «Usecases»).

В случае необходимости нарушить этот принцип необходимо дать имя функции, явно говорящее об этом
(например `get_or_create_*`).

## Load/save агрегата — в одной функции

Чтение агрегата через репозиторий (`get` / `get!` / `get_by_*` / `find_many` / `get_many` /
`list_*`, у event-sourced агрегата — `get_decision`) и его запись (`insert` / `update` / `save` /
`delete`, у event-sourced агрегата — `append`) MUST находиться в теле одной функции — вместе с
`Transact.run`, охватывающим обе операции.

- Мутации домена, разбор результата чтения и логирование выносить в чистые helper'ы без
  repo-вызовов.
- Batch: пачку перечитывает та же функция, которая сохраняет (`find_many` +
  `Result.traverse(list, &@repo.save(&1, context))`); верхний уровень передаёт вниз идентификаторы,
  а не загруженные агрегаты.
- Чтение без последующей записи (читающие usecases, history, чтение соседнего агрегата — например
  при проверке доступа) правилом не ограничено.
- Выборка кандидатов изменяющего фонового прогона через ReadRepo — не load агрегата; её условия —
  `13-repos.md`, «Read (`<Aggregate>.ReadRepo`)».

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

# event-sourced — получить и решить → записать события; следующая команда той же функции
# идёт от состояния из execute/2 без повторного чтения; транзакцию открывает Es.Transact
Es.Transact.run(fn ->
  with {:ok, {events, _account}} <-
         @repo.get_decision(id, version, context, &Account.execute(&1, command)),
       do: @repo.append(events, context)
end)
```

Резолв alternate key (`owner_id` → агрегат) отдельным чтением перед `get(id, version)` — тот же
разнос load/save, только внутри чтения: два SELECT ради одной проверки `version`. Поэтому
кастомный `get_by_*` проверяет `version` сам (`13-repos.md`, «Write (`<Aggregate>.Repo`)»).

Почему: `Repo.Sc` фиксирует эталон по первому чтению, а `Version` проверяется на записи. Разнесённые
load/save дают запись по устаревшей копии, немой пропуск `update`
(`Sc.find(context, Entity, id) == entity`) и невидимую в одном месте границу транзакции.

## Context — последний из данных

У функций, принимающих `%Context{}`, context MUST быть последним из данных: за ним MAY стоять
только колбэк и `opts \\ []`, ровно в таком порядке — `…, context, fun, opts \\ []`.

Исключение — модули, основная цель которых — работа с контекстом (`Context.Accessor` и производные
вроде `CurrentUser`; также `Repo.Sc`).

Колбэк идёт сразу за контекстом: он читается как продолжение вызова, а `fn ... end` в середине
списка прячет остальные аргументы за своим многострочным телом. `opts \\ []` замыкает сигнатуру —
аргумент со значением по умолчанию перед обязательным дал бы две арности с разным хвостом.

```elixir
# плохо — колбэк в середине, хвост вызова не виден за телом функции
with_lock(id, fn -> ... end, context, opts)

# хорошо — так же устроен `Core.Helper.Transact.run/3`
with_lock(id, context, fn -> ... end, opts)
```

## Наименование читающих функций: `find` / `get` / `get!`

| Имя | Возврат | Исключения |
|---|---|---|
| `find` | `T \| nil` | Допускается; SHOULD предпочитать `get` |
| `get` | `Result.t(T, reason)` | Не поднимать; ошибка — в `{:error, _}` |
| `get!` | `T` | При отсутствии/ошибке — `raise` |

Контракты repo-методов (`get`/`get!`/`list`/`page`/…) — см. `13-repos.md`.

```elixir
@spec find(Prim.t() | nil) :: term() | nil

def find(nil), do: nil
def find(%Prim{value: value}), do: value

@spec get(Prim.t() | nil) :: Result.t()

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

- Тип и форму аргументов SHOULD проверять pattern matching'ом в заголовке функции (или
  `case` / `with`), а не через `is_*` / `if` без необходимости.
- Составные общие guards — в `Core.Guard`; подключать через `import` (не `alias`). Не оборачивать
  тривиальные Kernel `is_*`.
  - Prim / struct: `is/2`, `is_opt/2` (`defguard`); обязательный Prim в head по умолчанию —
    `%Mod{}`.
  - Enum: `is_enum/2`, `in_enum/3` (макросы; subset сразу в `when`, без `@attr`; enum-модуль
    подтягивается через `ensure_compiled`). Enum собственного агрегата отдельным файлом MAY
    стоять в guard самого агрегата; имя enum MUST — через `alias` или полное: короткое имя без
    `alias` — несуществующий корневой модуль, и сборка падает `CompileError` (в проекте обычно
    `:unavailable`, а не `:nofile`).
  - Пример: `when is(id, User.ID) and is_opt(at, CreatedAt) and is_enum(status, Status)`.
- Доменные guards типа вне Guard — у источника типа (например `Version.is_version/1` для
  `t() | :current`).

## Документация

У каждого публичного модуля и публичной функции должны быть `@moduledoc` / `@doc`.

`Core.Enum` — строже: в `@moduledoc` MUST быть таблица с описанием **каждого** значения
(`11-domain.md`, «Описание значений в `@moduledoc`»).

## Спецификации типов

Каждая публичная функция MUST иметь `@spec`. `any()` и чрезмерно широкий `term()` — SHOULD NOT.

Роль `@spec`: в первую очередь документация сигнатуры, во вторую — Dialyzer. Домен допустимых
аргументов на этапе компиляции задают **clauses** / `when` (см. «Домен функции…»), не `@spec`.

Исключение — функции, которые генерирует макрос внутри `quote` под `@impl true`
(`Core.Repo.Pg`, `Core.Repo.Pg.StateStored`, `Core.Es.Aggregate.Repo.Pg`): источник типов
там — `@callback` соответствующего behaviour, а `@spec` пришлось бы собирать `unquote`-ом
из опций `use`. Обычный (не генерируемый) модуль с `@impl` от этого не освобождён —
`@spec` пишется как везде.

Исключение — функция, часть клауз которой генерирует сборка: `dump/2` / `load/3` плагина с
`fields:`. Спека ручной клаузы стала бы контрактом и сгенерированных, поэтому `@spec` там MUST NOT —
контракт задаёт `@callback` behaviour (`11-domain.md`, «Плагин по полям (`fields:`)»).

Проверяется: `CompileError` сборки плагина.

Исключение — экшены контроллера: их контракт описывает `operation/2`
(`deps/core/docs/rules/app/15-web-api.md`, «Controller»).

Визуально: после блока `@doc`/`@spec` — пустая строка, затем `def`/`defp` (или `@impl` + `def`).
`@doc` и `@spec` без пустой строки между собой. `@impl` остаётся рядом с функцией (разрыв между
`@spec` и `@impl`). Правило едино для одно- и многострочных спек.

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

### Форма результата

Результат в `@spec`, `@callback` и `@type` MUST записываться типами `Core.Result`, а не таплом
прописью: имя формы одно на библиотеку, а параметр называет причину. Формы и когда какая —
`11-domain.md`, «Result / Option»; решение — ADR-0070.

- Параметр, совпадающий с умолчанием, MUST NOT: `Result.t(a)`, а не `Result.t(a, Error.t())`;
  `Result.t()`, а не `Result.t(term())`; `Result.unit()`, а не `Result.unit(Error.t())`.
- Несколько причин — объединение в параметре: `Result.unit(:locked | Error.t())`.
- В `quote` — полный путь `Core.Result.t(…)`, как и у прочих модулей генерируемого кода.
- Форма с третьим вариантом (`{:skip, _}` у `Core.PubSub.handler_result`) и объединение unit с
  valued (`Core.Helper.Savepoint.result`) MAY оставаться таплом: через типы она длиннее и читается
  хуже. Конструктор одного варианта (`@spec error(a) :: {:error, a}`) — не результат.
- `a | nil` через `Option.t(a)` — не требуется.

```elixir
# плохо — форма переписана прописью
@spec get(ID.t(), Context.t()) :: {:ok, Agg.t()} | {:error, Error.t()}
@callback put(t(), Message.t()) :: :ok | {:error, Error.t()}
@type result :: :ok | {:error, {code(), detail()}}

# хорошо
@spec get(ID.t(), Context.t()) :: Result.t(Agg.t())
@callback put(t(), Message.t()) :: Result.unit()
@type result :: Result.unit({code(), detail()})
```

Проверяется: `make spec-check` (`scripts/spec_lint.exs`).

## Домен функции и инференс типов (Elixir 1.20+)

Система типов Elixir выводит допустимый домен аргументов из **clauses** (pattern matching / guards).
Лишняя clause, которая принимает «невалидный» вход и делает `raise`, расширяет домен и **скрывает**
ошибку от компилятора: вызов выглядит допустимым.

Длинный заголовок `def` / `when` допустим и предпочтителен перед упрощением ради короткой `@spec`.

Правила:

- Не добавлять catch-all / defensive-clauses «на всякий случай» с `raise ArgumentError` (и
  аналогами), если по контракту аргумент недопустим. Пусть неверный вызов даст `FunctionClauseError`
  на runtime, а при известном типе — предупреждение на compile time.
- Допустимый ввод описывать clauses и `@spec`/`@type`; недопустимый — **не** перечислять в
  заголовках функции.
- Исключение: явная обработка доменной/прикладной ошибки через `{:error, _}` или документированный
  `raise` на границе (`get!` / `unwrap!` при ожидаемом error-варианте контракта), а не
  «подстраховка» от неверного типа входа.

```elixir
# плохо — недопустимый вход в домене; инференс не ругается на вызов
def parse(:invalid, _opts), do: raise ArgumentError, "invalid"
def parse({:ok, data}, opts), do: do_parse(data, opts)

# хорошо — домен только допустимых форм; иное → FunctionClauseError / type warning
def parse({:ok, data}, opts), do: do_parse(data, opts)
```

### Генерируемые функции

Функция, которую макрос `Core` генерирует у потребителя, — граница типов: вызов через
модуль-переменную и функция `Core`, вызванная при его же сборке, дают компилятору `dynamic()`.
Почему граница стоит здесь — ADR-0014 (`docs/adr/0014-consumer-type-safety-by-inference.md`).

- Голова MUST закрывать struct паттерном (`%__MODULE__{}`, `%unquote(id){}`), а не `is_struct/2`:
  guard даёт открытую map, и опечатка в поле не ловится.
- Результат из библиотеки MUST сужаться паттерном в той же функции, код сужения — в
  `quote generated: true`: у части потребителей одна из clauses недостижима, и без разметки
  компилятор предупреждает в их сборке.
- Clause, недостижимая у части потребителей, MUST NOT возвращать голую переменную
  (`{:error, _} = error -> error`): её тело типизируется `dynamic()` и схлопывает весь результат.
- Bang-функция MUST делать `raise Core.Exc` сама, а не через `Core.Result.unwrap!/1`: результат
  `unwrap!` при сборке `Core` — `dynamic()`.

```elixir
# плохо — открытая голова, результат библиотеки без формы
quote do
  def execute(state, command) when is_struct(state, __MODULE__) and is_struct(command),
    do: Core.Es.Aggregate.execute(__MODULE__, state, command)
end

# хорошо
quote generated: true do
  def execute(%__MODULE__{} = state, command) when is_struct(command) do
    case Core.Es.Aggregate.apply_decision(__MODULE__, state, command, decide(command, state)) do
      {:ok, {events, %__MODULE__{} = executed}} when is_list(events) -> {:ok, {events, executed}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Проверяется: `make consumer-check` — предупреждения фикстуры-потребителя `fixtures/consumer`.

## Сборка struct

При конструировании с полями даты и пользователя (`created_at`, `created_by`, `at`, `by`, ...)
всегда указывать их последними. Сначала дата, затем пользователь (`at`, `by`). Если требуется
несколько таких пар — порядок: создание, обновление, удаление, т.е. `created_at`, `created_by`,
`updated_at`, `updated_by`, `deleted_at`, `deleted_by`.

## Алиасы модулей

Лист MAY алиаситься напрямую — короткое имя стоит рядом с вызовом и читается как имя операции:
`alias Core.Helper.Transact` → `Transact.warn_in_transaction(...)`.

Условие одно: короткое имя MUST быть свободно в этом файле. Занято модулем стандартной
библиотеки, зависимости или другим алиасом — leaf-алиас MUST NOT, конфликт разрешается алиасом
**родителя** и вызовом `Parent.Leaf.fun(...)`. Разводить конфликт через `as:` — SHOULD NOT:
переименование прячет настоящее имя модуля, а родитель его показывает.

```elixir
# плохо — `as:` вместо родителя
alias Core.Helper.Opts, as: UseOpts
UseOpts.validate!(...)

# хорошо — имя свободно, лист алиасится напрямую
alias Core.Helper.Transact
Transact.warn_in_transaction("публикация пачки в stream")

# хорошо — `String` занят стандартной библиотекой, поэтому через родителя
alias Core.Prim
Prim.String.new(value)
```

Типовые пространства, где лист напрямую не алиасится:

| Пространство | Лист | Что занимает имя |
|---|---|---|
| `Core.Prim`, `Core.Validator` | `String`, `Integer`, `Date`, `DateTime`, `Decimal` | одноимённые модули Elixir и `decimal` |
| `Core.Repo` | `Pg`, `Sc` | рядом нужен сам `Core.Repo` (`use Repo.Pg`, `@behaviour Core.Repo`) |
| `Core.Codec` | `Facade`, `Plugin`, `Redump` | рядом нужен сам `Core.Codec` (`use Core.Codec`) |
| `MyAppWeb.<Api>.<Version>.<Resource>` | `Params` | лист занят `Core.Web.Params` (`alias Core.Web.Params` в контроллере): разбор входа ресурса адресуется через родителя (`<Resource>.Params.Filter`) |

Совпадение со **std-модулем, которого в файле нет**, конфликтом не считается: `alias Core.Version`
затеняет `Version` из Elixir осознанно — semver в домене не используется. Появилась нужда в
затенённом модуле — звать его полным путём (`Elixir.Version.match?/2`), а не переименовывать свой.

Когда родитель имена не разводит (`Core.Repo` и `Repo` другого пространства — оба листа зовутся
`Repo`), остаётся полный путь для одного из двух; `as:` — последнее средство, и только на одном
из конфликтующих.

Листовые модули без вложенности (`Error`, `Exc`, `Context`) — алиасить напрямую, без `as:`.

Алиасы модулей приложения (профили Codec, репозиторий агрегата) —
`deps/core/docs/rules/app/20-agreements.md`, «Алиасы приложения». Кастомные Prim профиля,
entity-плагины и фасад — `11-domain.md`, «Codec (Prim и Entity)».

### Dump/load только через фасад

Вложенные сущности и соседние типы — **только** через фасад (`InCodec` / `OutCodec`) или через
аргумент `codec` внутри плагина; звать модуль чужого плагина напрямую — MUST NOT. Правила и
примеры — `11-domain.md`.

## Правило понижения

Требуется придерживаться правила понижения.

**Правило понижения** — организация кода, при которой модуль читается как последовательный рассказ
сверху вниз. За каждой функцией следуют функции следующего уровня абстракции; читатель
последовательно спускается по уровням абстракции.

Основные характеристики:

- Код читается как хорошо написанная газетная статья
- Сначала — высокоуровневые концепции и алгоритмы
- Степень детализации увеличивается к концу файла
- В конце — функции и подробности низшего уровня
- Взаимозависимые функции — в нисходящем порядке (вызываемая ниже вызывающей)

Так проще понять структуру модуля по начальным функциям, не погружаясь сразу в детали реализации.

## Разделители внутри модуля

Маркера два, и это два уровня одной модели, а не два режима разметки:

- `# ---` — падение уровня абстракции внутри блока: ниже идут детали реализации того, что выше;
- `# ===== <имя> =====` — граница смыслового блока, то есть возврат уровня наверх.

Публичное — `def` / `defmacro` / `defguard` / `defdelegate`; приватное — `defp` / `defmacrop` /
`defguardp`. Переходом считается любая пара из этих списков.

Форма — ровно `# ---` и `# ===== <имя> =====` (пять `=` с каждой стороны), отступ — как у
определений модуля (внутри условной сборки `if Code.ensure_loaded?(…)` — как у определения под
маркером), пустая строка сверху и снизу. Маркер MUST стоять перед `@doc` / `@spec` первой
функции, а не между спекой и определением.

Внутри `quote` разделитель MUST NOT: он принадлежит модулю, куда инжектится код. Вложенный
`defmodule` размечается самостоятельно — со своим счётом блоков. Модуль без публичных функций
(например `<Aggregate>.Event.Codec`, где публичный API генерирует макрос) разделителя не требует:
отделять нечего. В `test/**` вне `test/support/**` разметка MAY — приватные хелперы идут после
`test`-блоков; форма маркеров общая.

Проверяется: `make layout-check` (`scripts/layout_lint.exs`) — форма маркеров, наличие на каждом
переходе, счёт блоков и хвостовой блок, `# ---` перед блоком `общее`, маркер внутри `quote`; в
`test/**` вне `test/support/**` — только форма.

Почему уровня два и почему общий приватный живёт в хвосте — ADR-0012
(`docs/adr/0012-module-separators.md`).

### Переход к приватным (`# ---`)

Переход public → private MUST размечаться строкой `# ---`, и **на каждом** переходе: по правилу
понижения приватный хелпер стоит сразу под своим публичным вызывающим, и таких переходов в модуле
несколько. Каждый читается как «ниже детали реализации того, что выше».

```elixir
def archive(%Agg.ID{} = id, %Context{} = context), do: archive_many([id], context)

# ---

defp archive_groups(groups, by, context) do
```

### Блоки (`# ===== … =====`)

Возврат private → public — не продолжение прежнего рассказа, а начало нового: уровень абстракции
вернулся наверх. Такой возврат открывает блок и MUST быть предварён `# ===== <имя> =====`.

- модуль с одним блоком маркер `# ===== =====` MUST NOT нести — отделять нечего, хватает `# ---`;
- модуль с двумя и более блоками размечает каждый блок, включая первый;
- имена блоков — русские (`билдер`, `опции профиля`); английское имя MAY, только если это термин
  кода (`dump`, `load`, `coerce`, `decide`, `evolve`).

```elixir
# плохо — публичная функция после приватных: возврат наверх не виден
defp to_datetime_fmt(%DateTime{} = dt, :datetime), do: dt

@spec load_builtin(module(), term(), atom()) :: Result.t()

def load_builtin(mod, raw, _kind) when is_atom(mod), do: mod.new(raw)

# хорошо — возврат наверх и есть граница блока
defp to_datetime_fmt(%DateTime{} = dt, :datetime), do: dt

# ===== load =====

@spec load_builtin(module(), term(), atom()) :: Result.t()

def load_builtin(mod, raw, _kind) when is_atom(mod), do: mod.new(raw)
```

### Общие приватные

Приватный, вызываемый более чем из одного блока, MUST жить в хвостовом блоке `# ===== общее =====`:
деталью одного блока он не является и под любым из вызывающих читается как чужой. Блок `общее` —
только последний в модуле; `# ---` перед ним и внутри него MUST NOT: переход к его приватным
размечает сам маркер блока, а внутри отделять нечего.

Хвост из **всех** приватных модуля — MUST NOT: правило понижения держит хелпер под его публичным
вызывающим, и в `общее` уезжает только тот, у кого вызывающий не один.

## Стиль кодирования

В `use` каждый передаваемый параметр обязан быть на отдельной строке.
Список атомов должен описываться через ~w(...)a

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

### Схема опций функции

Функция, которая сама читает свои опции (`CONTEXT.md`, «Опции функции»), объявляет схему опций
`@opts_schema` над `def` в модуле с `use Core.Options`: в `lib/` библиотеки — MUST, у потребителя —
SHOULD. В `lib/` библиотеки `Keyword.validate!` и ручная клауза проверки типа опции у такой
функции — MUST NOT.

- Схема — NimbleOptions, у каждого ключа `doc:` строкой. Тело получает опции с умолчаниями и
  читает их `Keyword.fetch!/2` без запасного значения; ключ без `default:` — `Keyword.get/2`, тоже
  без запасного значения: его отсутствие — штатный случай, а умолчание, зависящее от другой опции
  или аргумента, тело вычисляет само (`Keyword.get(opts, :name) || derived`).
- Custom-тип схемы (`{:custom, mod, fun, args}`) MUST быть чистой функцией значения и `args`: без
  env, ETS, процессов и часов. У схемы без обязательных ключей вызов с `[]` NimbleOptions не
  проходит, а получает умолчания, проверенные при сборке: зависящий от рантайма валидатор ответил бы
  на `[]` по состоянию сборки, а на непустых опциях — по текущему.
- Функция, передающая `opts` насквозь (в Ecto, в `Core.Helper.Transact.run/3`), схему MUST NOT:
  ключи проверяет тот, кому они переданы.
- Опции в голове функции со схемой MUST быть переменной; guard на них — только `is_list/1`.
- Конструктор из keyword (`new(opts)`) читает свои опции сам: схема над ним — как у любой функции
  (`Core.Mq.Stream.Credentials.new/1`). Поля значения — опции конструктора, а не «данные в форме
  опций».
- Параметр `opts` у `def` в `lib/` — только опции самой функции. Keyword, который функция сама не
  читает, — опции объявления Prim, опции `use`, отданные функции builder'а, уже проверенные опции
  вызывающего, — MUST называться иначе (`pipeline_opts`, `type_opts`, `use_opts`): проверку ниже
  включает имя `opts`.
- `@spec` пишет автор, тип опций — `keyword()`.
- Данные в форме опций, которые не последний аргумент функции (элементы позиционного списка),
  проверяются `Core.Options.validate!/3` по схеме, собранной `NimbleOptions.new!/1` в атрибуте
  модуля. Опции самой функции так MUST NOT: их проверяет `@opts_schema`.
- Проверка после схемы (межключевая, по соседнему модулю) MUST отказывать `ArgumentError` с тем же
  префиксом `<Mod.fun/n>:`, что и схема: из одной функции — один формат отказа.
- Раздел «Опции» в `@doc` собирается из схемы; прозой состав опций в `@doc` MUST NOT — она
  разойдётся с проверкой. Скрытый `init/1` OTP-процесса (`@doc false`, `@impl` без `@doc`) раздела
  не получает: описание опций старта MUST вставляться в `@moduledoc` вызовом `Core.Options.docs/1`.
- `@opts_schema` над `defp` / `defmacro` и внутри `quote` генерируемого кода — MUST NOT. Опции
  `use` разбирает `Core.Helper.Opts` («Опции `use`»).

```elixir
# плохо — опечатка в ключе проверяет только Keyword.validate!, тип значения — никто
def run_once(projection, opts \\ []) when is_atom(projection) and is_list(opts) do
  [batch_size: batch_size] = Keyword.validate!(opts, batch_size: 100)
  ...
end

# хорошо
use Core.Options

@opts_schema [batch_size: [type: :pos_integer, default: 100, doc: "Сколько событий читает пачка."]]
@spec run_once(module(), keyword()) :: outcome()

def run_once(projection, opts \\ []) when is_atom(projection) and is_list(opts) do
  batch_size = Keyword.fetch!(opts, :batch_size)
  ...
end
```

Отказ вызова — `ArgumentError` `"<Mod.fun/n>: <сообщение NimbleOptions>"` до входа в тело. Почему
подмена `def`, а не обёртка, — ADR-0086 (`docs/adr/0086-function-opts-schema.md`).

Проверяется: `CompileError` сборки (`Core.Options`) — ключ без `doc:`, атрибут над `defp` /
`defmacro`, висячий атрибут, атрибут между головой без тела и первой клаузой, паттерн или guard
кроме `is_list/1` на опциях; раздел «Опции» — `test/core/options_docs_test.exs`; функция `lib/`,
читающая опции мимо схемы, — `mix credo --strict` (`CredoChecks.OptsSchema`,
`scripts/credo_checks.exs`): `Keyword.validate!(opts, …)`, `Keyword.get/fetch/fetch!(opts, …)` и
`opts[:…]` в публичной функции без `@opts_schema`, в том числе через приватную функцию модуля.
Проверка видит только параметр с буквальным именем `opts`: опции под другим именем она пропускает.
Не срабатывает на обратном вызове с `@impl`, на функции, отдающей `opts` целиком дальше
(аргументом вызова, в спецификации ребёнка), и в модулях разбора опций как данных (параметр
`parsers:` проверки).

### Однострочные клаузы

Однострочные клаузы одной функции (одно имя и арность, `def name(…), do: …` в одной физической
строке) MUST идти подряд, строка за строкой, без пустых строк и маркеров `# ---` между ними:
такая группа читается как одна таблица «вход → выход», и разрыв выдаёт её за разные функции.

```elixir
# плохо — пустая строка рвёт таблицу клауз
def dump(nil), do: nil

def dump(value) when value in @enum_values, do: Atom.to_string(value)

# хорошо
def dump(nil), do: nil
def dump(value) when value in @enum_values, do: Atom.to_string(value)
```

### Вложенные колбэки: `bind`

Bracket-функция принимает колбэк последним аргументом (`File.open/3`,
`Core.Helper.Transact.run/3`, `:timer.tc/1`), и цепочка таких вызовов растёт вправо.
Разворачивать её MAY `Core.Bind.bind/1` (`import Core.Bind`): строка `pattern <- call`
становится колбэком для всего, что ниже.

- Шаг, которому подходит имя, SHOULD выносить в приватную функцию, а не в строку `bind`:
  имя объясняет шаг, `bind` — нет.
- Шаг с результатом — `pattern <- Result.and_then(call)` (`Core.Result.and_then/2`, `result.try`
  из Gleam): `x <-` принимает `{:ok, x}`, `[] <-` — `:ok`, ошибка становится итогом блока,
  не-результат справа — `FunctionClauseError`.
- Смешанная цепочка (bracket-шаги и шаги с результатом) MAY через `bind`; чистая цепочка
  результатов — `with` или `bind`, выбор автора.
- Ошибку, которой нужна обработка по клаузам, SHOULD разбирать `with` с `else`. У `bind` `else`
  нет: ошибка шага правится `Result.map_error/2` справа до `Result.and_then/2`, ошибка блока —
  `bind do … end |> Result.map_error(…)` или `|> case do … end` с клаузой пропуска успеха.
  Почему `else` у `bind` не будет — ADR-0026 (`docs/adr/0026-bind-result-steps.md`).
- Форма слева задаёт параметры колбэка: `x` / `{:ok, x}` — один, `[]` — нуль-арный,
  `[a, b]` — двухарный; промах паттерна — `FunctionClauseError`. Список-паттерн MUST оборачивать
  в список параметров: `[[a, b]] <-` даёт `fn [a, b] ->`.
- Хвост после колбэка задаётся маркером `_` среди аргументов верхнего уровня
  (`Transact.run(DAO, _, timeout: :infinity)`).
- Справа от `<-` MUST стоять вызов, принимающий колбэк последним аргументом; литерал,
  оператор, сигил и форма с `do`-блоком дают `CompileError`.

```elixir
# плохо — два уровня отступа ради двух bracket-вызовов
File.open(path, [:read], fn io ->
  :timer.tc(fn ->
    IO.read(io, :line)
  end)
end)

# хорошо
bind do
  io <- File.open(path, [:read])
  [] <- :timer.tc()
  IO.read(io, :line)
end

# смешанная цепочка одним блоком — равноправно с `with` внутри `Transact.run(DAO, fn -> … end)`
bind do
  [] <- Transact.run(DAO, _)
  settings <- Result.and_then(@repo.get_by_owner_id(owner_id, version, context))
  settings <- Result.and_then(apply_attrs(settings, owner_id, attrs))
  _saved <- Result.and_then(@repo.save(settings, context))
  :ok
end
```

Проверяется: `test/core/bind_test.exs` — шаг с результатом, не-результат справа,
`CompileError` на `else` и на не-вызов справа от `<-`.

### Safe vs bang

В application-flow с контрактом `:ok | {:error, _}` / `{:ok, T} | {:error, _}` предпочитать safe API
(`get`, `new`, `from_events`, …), а не bang.

Bang (`get!`, `new!`, `raise Exc`, …) — только на явных bang-границах. Исключения: Schema
bang-mappers (`to_entity!` / `to_model!`) на call site своих строк / persist валидного domain;
реконструкция события `InCodec.load!` в тестах (`Core.Es.Store.Test.events!`); аксессор текущего
пользователя (`use Core.Context.Accessor`) `get!/1` в ACL-фильтре; compile-time константы
(Prim-константа в атрибуте модуля (`new!`) и т.п.); OTP/config init; загрузка потока
`Core.Es.Store.load_fold_rows/4` при свёртке в `Core.Es.Aggregate.Repo.Pg` (нечитаемое событие
— исключение, сбой хранилища ключей — `{:error, _}`, `13-repos.md`); `codec.load!` id владельца
в `find/2` модуля ключа (`use Core.Es.KeyReservation`) — строку резерва пишет `append`
репозитория, и нечитаемый id — исключение; любая чистая операция над событием и константами кода
(Prim, реестр, заданный литералом в коде) в `evolve/2` event-sourced агрегата — колбэк
возвращает голое состояние (`@callback evolve(state, event) :: struct()`), вернуть `{:error, _}`
ему некуда, а отказ такой операции — нечитаемое событие или ошибка программиста, и он исключение,
как загрузка потока при свёртке.

Schema-мапперы (dual API `to_entity` / `to_entity!`) — какой вызов на каком call site:
`13-repos.md`, раздел «Schema»; события страницы потока грузятся safe — там же, «Страница потока».

Конверсия datetime-Prim в domain flow (мутации агрегатов), кроме `evolve/2`:
только `from` + `with` (`CreatedAt.from`, `UpdatedAt.from`, `Es.Event.At.from`, …), не `from!` и
без обёрток вроде `event_at/1` — на call site сразу `Es.Event.At.from(at)`.

Текущее время в Result-flow: `now` + `with` (`CreatedAt.now()`, …); bang-границы / OTP / тесты —
`now!`. Это доменное время; инфраструктура библиотеки берёт реальное через `new` (`11-domain.md`,
«Доменное время (`Core.Clock`)»).

Repo Specs / ACL-фильтры, которым по контракту **обязан** быть current user в `Context` (например
`get!/1` аксессора текущего пользователя (`use Core.Context.Accessor`) в ACL-фильтре): отсутствие
ID — ошибка программиста; bang допустим.

### Использование try

Если тело try больше одной строки — вынести в отдельную приватную функцию.

При работе с ресурсами использовать конструкцию try after для гарантированного
закрытия/очистки, при условии, что нет более специализированного решения.

## Связанные правила

- Архитектура и границы библиотеки — `10-architecture.md`
- Домен, `Prim`, `Codec` — `11-domain.md`
- Ошибки — `12-errors.md`
- Репозитории и Schema-мапперы — `13-repos.md`
- События и outbox — `14-events-outbox.md`
- OTP — `17-otp-concurrency.md`
- Тесты — `19-testing.md`
- Метрики, трейсы, логи — `21-observability.md`
