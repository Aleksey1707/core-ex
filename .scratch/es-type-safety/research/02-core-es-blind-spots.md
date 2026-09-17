# Слепые зоны компилятора в коде потребителя `Core.Es`

Исследование на 2026-09-17. Версии: Elixir 1.20.3 (OTP 29), core-ex 47f692f.

## Вопрос

Какие ошибки в коде приложения-потребителя `Core.Es` компилятор Elixir 1.20.3 сообщает, а какие пропускает.
Потребитель пишет агрегат, команды, события, кодек, репозиторий, процесс и проекцию. Для пропущенных ошибок
нужен исход в runtime. Для функций, которые генерируют макросы `Core.Es`, и для функций библиотеки, в которые
они пересылают вызов, нужны выведенные сигнатуры. Механика вывода и проверки описана в
`01-elixir-1-20-type-system.md`; ниже ссылка на неё — [01 §N] или [01 «раздел»].

Методика и обозначения:

- **Сборка.** Mix-проект `02-experiments/` (`app: :blind`) [24]. Зависимости:
  `{:core, path: "../../../.."}` на HEAD 47f692f и
  `{:hackney, "~> 4.0.1", override: true}`, как в qc [23].
  - `mix.lock` скопирован из core-ex. `HEX_OFFLINE=1 mix deps.get` взял пакеты из локального кеша
    `~/.hex/packages/hexpm`, сеть не понадобилась.
  - `mix deps.compile` собрал core в `_build/dev` эксперимента без предупреждений. `deps` и `_build` core-ex
    не менялись. Optional-клиентов брокеров нет, `git init` не выполнялся.
- **Конфигурация:** `config :core, otp_app: :blind, dao: Blind.DAO, codec: Blind.Codec.Internal` [24].
- **Потребитель** собран по образцу `test/support/es_fixture` [13]:
  - `Blind.Account`: события `Opened` и `Renamed` с нагрузкой, `Closed` без неё; команда `Cmd.Orphan` без
    clause в `decide`.
  - `Blind.Order` — «чужой» агрегат: `Placed` с нагрузкой, `Cancelled` без.
  - У обоих есть ID, команды, `Event.Codec`, `Errors`, `Outbox`, `Repo`, `Repo.Pg`, `Process`.
  - Кроме того: `Blind.UserID`, проекция `Blind.Projection`, фасад `Blind.Codec.Internal` и `Blind.Parcel` —
    события и кодек с намеренными дырами.
  - Без сценариев проект компилируется без предупреждений [25].
- **Сценарий** — отдельная функция с одной ошибкой в `lib/scenarios/*.ex` [26–36]. Аргументы сужены паттерном в
  голове (`%Account{} = state`), как в usecase qc [16:172-205]. Ошибочные агрегаты и проекция вынесены в
  отдельные модули: `BadDecide`, `BadEvolve`, `BadEvolveState`, `QcStyle`, `BadProjection`.
- **Репозиторий** вызывается так же, как в qc: `@repo Core.Config.repo!(Blind.Account.Repo)` и
  `@repo.get(id, :current, context)` [16:35, 175]. Атрибут раскрывается в литерал `Blind.Account.Repo.Pg`
  [01 §2].
- **Вывод компилятора** — `mix compile --force` → `compile.out`, 47 предупреждений [37]. Ниже он сокращён до
  заголовка, типов и места.
- **Runtime** — `mix run runtime.exs` → `runtime_results.out` [38]. БД не запускалась: `Blind.DAO` не стартован.
  Если исход требует транзакции, в таблице стоит «нужна БД» и исход по коду. Шаг до транзакции, где это
  возможно, вызван отдельно.
- **Сигнатуры** — `mix run --no-compile --no-start sig.exs Mod:fun/arity` → `sigs_*.out` [39]. Для сравнения те же
  функции фикстуры прочитаны из сборки самого core-ex (`_build/test` от 2026-09-15, только чтение) [40].
- **qc** подключает core тегом `v0.2.1` [23], эксперимент идёт на HEAD core-ex. `Agg.Process.execute` в `lib/`
  qc не вызывается. Команда в qc: `QC.Transact.run` → `@repo.get` → `Agg.execute/2` → `@repo.append`
  [16:172-202][17:150-173].

## Что определяет исход

1. **Сгенерированная функция** — обычная `def` модуля потребителя [01 §3].
   - Домен задают паттерны и guards головы из `quote`.
   - Результат равен сигнатуре функции `Core.*`, в которую пересылается вызов: зависимость участвует в выводе
     [01 «Зависимость»].
   - В самом core-ex те же функции выводятся с результатом `dynamic()` [40]:

   | Функция | У потребителя [39] | В core-ex, тот же проект [40] |
   |---|---|---|
   | `Agg.execute/2` | `(%{..., __struct__: Agg}, %{..., __struct__: atom(), at: term(), by: term()} -> dynamic({:error, %Core.Error{}} or {:ok, {term(), term()}}))` | `(%{..., __struct__: Agg}, %{..., __struct__: atom()} -> dynamic())` |
   | `Agg.Repo.Pg.get/3` | `(… -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` | `(… -> dynamic())` |

2. **Домены голов в `quote`:**

   | Голова | Домен |
   |---|---|
   | `is_struct(state, __MODULE__)` | `%{..., __struct__: Agg}` |
   | `is_struct(command)` | любой struct |
   | `%unquote(id){}` | `%Agg.ID{}` |
   | `is_version(version)` | `%{..., __struct__: Core.Version} or :current` |
   | `is_list(events)` | `list(term())` |
   | `is_function(fun, 1)` | только арность |

3. **Вызовы кода потребителя из библиотеки** всегда идут через модуль-переменную:
   - `aggregate.decide` [1:150] и `aggregate.evolve` [1:185];
   - `mod.new` [1:216, 219][4:435, 438];
   - `projection.project` [8:batch.ex:202] и `module.load` [4:398];
   - `cfg.aggregate.execute` [7:67].

   Такой вызов не проверяется, его результат — `dynamic()` [01 §2, §4].
4. **Prim-конструкторы без `{:ok, _}` возвращают `dynamic()`.** Это `ID.new/0`, `Name.new!/1`, `Version.new/0`,
   `Es.Event.At.now!/0`. Цепочка: `new/0` → `new!/1` → `Core.Result.unwrap!/1` с сигнатурой
   `({:ok, term()} -> dynamic())` [10][39]. Для сравнения: `ID.new/1` → `dynamic({:error, term()} or {:ok, %ID{}})`,
   `At.now/0` → `dynamic({:error, term()} or {:ok, %Core.Es.Event.At{}})`. Значение `dynamic()` совместимо с
   любым доменом [01 «Семантика dynamic()»].

## 1. `Agg.execute/2`

```elixir
def a1_foreign_cmd(%Account{} = state, %Order.Cmd.Place{} = cmd), do: Account.execute(state, cmd)
def a3_foreign_state(%Order{} = state, %Account.Cmd.Open{} = cmd), do: Account.execute(state, cmd)

def a4b_with_append(%Account{} = state, %Account.Cmd.Open{} = cmd, %Context{} = context) do
  with {:ok, events} <- Account.execute(state, cmd), do: @repo.append(events, context)
end

def a5a_state_typo(%Account{} = state, %Account.Cmd.Open{} = cmd) do
  {:ok, {_events, executed}} = Account.execute(state, cmd)
  executed.nmae
end
```

```
warning: incompatible types given to Blind.Account.execute/2:
    given types: -dynamic(%Blind.Order{})-, dynamic(%Blind.Account.Cmd.Open{})
    but expected one of: %{..., __struct__: Blind.Account}, %{..., __struct__: atom(), at: term(), by: term()}
└─ lib/scenarios/a_execute.ex:22:17: Blind.S.Execute.a3_foreign_state/2

warning: incompatible types given to Blind.Account.Repo.Pg.append/2:
    given types: -dynamic({term(), term()})-, dynamic(%Core.Context{})
└─ lib/scenarios/a_execute.ex:35:13: Blind.S.Execute.a4b_with_append/3

warning: the following clause will never match:
    {:ok, events} when is_list(events) ->
which has type: dynamic({:error, %Core.Error{}} or {:ok, {term(), term()}})
└─ lib/scenarios/a_execute.ex:27: Blind.S.Execute.a4a_case_events_list/2
```

- **Ловится:**
  - A3 — состояние чужого агрегата;
  - A4a–A4c — `{:ok, events} when is_list(events)`, `with {:ok, events}` с передачей в `append`, clause `:ok ->`;
  - A6 — `%Account.Name{}` вместо команды;
  - A7 — map `%{by:, at:}` вместо struct;
  - A5b — опечатка после сопоставления `{:ok, {_, %Account{} = executed}}`.
- **Молчат:** A1 (команда чужого агрегата), A2 (команда без clause), A5a (опечатка в поле состояния), A5c
  (опечатка в поле события из результата).
- **Причины:**
  - Домен команды `%{..., __struct__: atom(), at: term(), by: term()}` складывается из `is_struct(command)`
    [1:117] и паттерна `%{by: by, at: at} = command` библиотеки [1:148]. Поэтому A6 и A7 ловятся: у них нет
    struct или `by`/`at`. Любая команда с `by`/`at` проходит, а `decide` вызывается через модуль-переменную
    [1:150].
  - Форма результата `{:ok, {term(), term()}}` берётся из `Core.Es.Aggregate.execute/3` [1:148-158]. Состояние
    сворачивает `Enum.reduce` с `aggregate.evolve`, поэтому элементы кортежа — `term()` [01 §4, §10].

Прямой вызов `Account.decide/2` для сравнения. Сигнатура — 6 clauses по паттернам [39]:

```
warning: incompatible types given to Blind.Account.decide/2:
    given types: -dynamic(%Blind.Order.Cmd.Place{})-, dynamic(%Blind.Account{})
    but expected one of: #1 %Blind.Account.Cmd.Open{}, %Blind.Account{version: nil} … #6
└─ lib/scenarios/a_execute.ex:76:17: Blind.S.Execute.d1_foreign_cmd/2

warning: the following clause will never match:
    {:ok, {events, _state}} ->
which has type: dynamic({:error, term()} or {:ok, non_empty_list({Blind.Account.Event.Opened, term()})})
└─ lib/scenarios/a_execute.ex:86: Blind.S.Execute.d4_case_state_tuple/2
```

- **Ловятся:**
  - A-d1 — чужая команда;
  - A-d2 — `Cmd.Orphan`;
  - A-d3 — чужое состояние;
  - A-d4 — `{:ok, {events, state}}` по результату `decide`.
- **Молчит:** A-d5 — опечатка в поле нагрузки из `{:ok, [{_mod, payload}]}`. Нагрузку строит
  `Event.Opened.Payload.new(name)`, модуль того же проекта, поэтому при выводе элемент — `term()`
  [01 «Тот же проект»].

## 2. Результат `decide`

```elixir
defmodule Blind.BadDecide do
  use Core.Es.Aggregate, event_codec: Blind.Account.Event.Codec
  def decide(%Cmd.Open{}, %__MODULE__{}),                           # B1: модуль не из tags:
    do: {:ok, [{Order.Event.Placed, %Order.Event.Placed.Payload{amount: nil}}]}
  def decide(%Cmd.Rename{name: name}, %__MODULE__{}),               # B2: чужая нагрузка
    do: {:ok, [{Event.Opened, %Event.Renamed.Payload{name: name}}]}
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Opened]} # B3: голый модуль с нагрузкой
end
```

Выведенная сигнатура знает результат точно [39]:

```
(%Blind.Account.Cmd.Open{}, %Blind.BadDecide{} -> {:ok, non_empty_list({Blind.Order.Event.Placed, %Blind.Order.Event.Placed.Payload{amount: nil}})})
(%Blind.Account.Cmd.Rename{}, %Blind.BadDecide{} -> dynamic({:ok, non_empty_list({Blind.Account.Event.Opened, %Blind.Account.Event.Renamed.Payload{}})}))
(%Blind.Account.Cmd.Close{}, %Blind.BadDecide{} -> {:ok, non_empty_list(Blind.Account.Event.Opened)})
```

- **Молчат** B1–B3 через `BadDecide.execute/2`, а также B4 и B5 — те же результаты прямым вызовом
  `Account.fold(state, cmd, results)`. Ни при определении `decide`, ни при вызове предупреждений нет.
- **Runtime** (без БД):
  - B1 и B4 — `FunctionClauseError` в `Core.Es.Aggregate.event/6`: guard `is_map_key(mods, mod)`;
  - B2 — `FunctionClauseError` в `Blind.Account.Event.Opened.new/6`;
  - B3 и B5 — `UndefinedFunctionError` `Opened.new/4`.
- **Причины:**
  - Результат `decide` ни с чем не сверяется. `execute/3` получает его из вызова через модуль-переменную [1:150],
    `events/5` и `event/6` зовут `mod.new` через переменную [1:200-219] [01 §2, §4].
  - Домен `fold/3` — `list(term())` [39].
  - Тип `@callback decide` не читается [01 «`@callback`»].

## 3. `evolve`

```elixir
defmodule Blind.BadEvolve do
  use Core.Es.Aggregate, event_codec: Blind.Account.Event.Codec
  def evolve(state, %Event.Opened{payload: %Event.Opened.Payload{} = payload}), do: %{state | name: payload.nmae} # C2b
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.nmae}                        # C2a
  # C1: нет clause для Event.Closed
end

defmodule Blind.BadEvolveState do   # C4
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | nmae: payload.name}
end
```

```
warning: unknown key .nmae in expression:
    payload.nmae
the given type does not have the given key: dynamic(%Blind.Account.Event.Opened.Payload{name: term()})
└─ lib/scenarios/c_evolve.ex:18:33: Blind.BadEvolve.evolve/2

warning: incompatible types given to Blind.Account.evolve/2:
    given types: dynamic(%Blind.Account{}), -binary()-
└─ lib/scenarios/c_evolve.ex:71:61: Blind.S.Evolve.c3_direct_evolve_bad/1
```

**C1 — нет clause для события из `tags:`.**

- **Компиляция:** сигнала нет ни в каком виде.
  - `@after_compile` агрегата проверяет только поля `id`/`version` [1:125-140].
  - `@impl`/`@behaviour` проверяют наличие `evolve/2`, но не полноту [01 «`@callback`»].
  - Проверки исчерпываемости в 1.20.3 нет [01 §9].
  - Полноту проверяет только тест `use Core.Es.EventCompatCase, aggregate:` [12:29-31].
- **Молчат** `BadEvolve.fold(state, [closed])` и `BadEvolve.execute(state, %Cmd.Close{})`.
- **Ловится** прямой вызов `BadEvolve.evolve(state, %Closed{})`: домен — `Opened or Renamed`.
- **Runtime:** `FunctionClauseError` в `Blind.BadEvolve.evolve/2`.

**Остальные случаи:**

- **C2a** — опечатка в поле нагрузки при `%Event.Renamed{payload: payload}` — молчит при определении и через
  `execute`, runtime `KeyError`. Значение поля в паттерне struct — `term()`, `payload.nmae` лишь сужает домен
  до `payload: %{..., nmae: term()}` [01 «Поля struct», §8].
- **C2b** — та же опечатка при `payload: %Payload{} = payload` — ловится при определении.
- **C3** — `Account.fold(state, ["bad"])` молчит: домен `fold/2` — `list(term())`. Runtime —
  `FunctionClauseError` в `Core.Es.Aggregate.step/3`. Прямой `Account.evolve(state, "bad")` ловится.
- **C4** — опечатка в ключе `%{state | nmae: …}` молчит при определении и через `execute`, runtime `KeyError`.
  Домен clause становится `%{..., nmae: term()}` [39]. Прямой вызов с `%BadEvolveState{}` ловится.
- **C5** (сверх списка) — `Account.fold(state, [событие Order])` молчит. Runtime — `ArgumentError`
  «событие чужого агрегата» из `step/3` [1:189-193].

## 4. Конструктор события

`new/5,6` генерируется с паттернами `%Payload{}`, `%Agg.ID{}`, `%Version{}`, `%By{}`, `%Es.Event.At{}` в голове
[3:149-170]. Сигнатура [39]:

```
Blind.Account.Event.Opened:new/5
    (%Blind.Account.Event.Opened.Payload{}, %Blind.Account.ID{}, %Core.Version{}, %Blind.UserID{}, %Core.Es.Event.At{} -> dynamic(%Blind.Account.Event.Opened{payload: %…Payload{}, aggregate_id: %Blind.Account.ID{}, …}))
```

```
warning: incompatible types given to Blind.Account.Event.Opened.new/5:
    given types: (dynamic(%…Opened.Payload{}), -dynamic(%Blind.Order.ID{})-, dynamic(), dynamic(%Blind.UserID{}), dynamic(%Core.Es.Event.At{}))
└─ lib/scenarios/d_event_new.ex:22:30: Blind.S.EventNew.d2_foreign_aggregate_id/4

warning: incompatible types given to Blind.Account.Event.Closed.new/4:
    given types: dynamic(%Blind.Account.ID{}), dynamic(), dynamic(%Blind.UserID{}), -dynamic(%DateTime{})-
└─ lib/scenarios/d_event_new.ex:44:30: Blind.S.EventNew.d4_datetime_at/2
```

- **Ловятся:**
  - D1 — литерал чужой нагрузки;
  - D1b — `Renamed.Payload.new(name)`, модуль того же проекта, при проверке `dynamic(%Renamed.Payload{…})`;
  - D1c — map вместо нагрузки;
  - D2 — чужой ID из паттерна;
  - D2c — `{:ok, id} = Order.ID.new(raw)`;
  - D3 — чужой Prim в `by`;
  - D4 — `DateTime` вместо `At`;
  - D4b — целое вместо `Version`;
  - D5 — опечатка в поле события, возвращённого `new/4`.
- **Молчат:** D2b и D3b — чужой ID из `Order.ID.new()` в `aggregate_id` или `by`. `new/0` возвращает `dynamic()`
  («Что определяет исход», п. 4). Runtime — `FunctionClauseError` `Opened.new/6`.

## 5. Репозиторий

```elixir
@repo Core.Config.repo!(Blind.Account.Repo)

def e1_foreign_id(%Order.ID{} = id, %Context{} = context), do: @repo.get(id, :current, context)
def e1b_foreign_id_new(%Context{} = context), do: @repo.get(Order.ID.new(), :current, context)
def e2_int_version(%Account.ID{} = id, %Context{} = context), do: @repo.get(id, 1, context)
def e3_append_not_event(%Context{} = context), do: @repo.append(["bad"], context)

def e4_case_get(%Account.ID{} = id, %Context{} = context) do
  case @repo.get(id, :current, context) do
    {:ok, {_events, state}} -> state
    :ok -> nil
    {:error, _error} -> nil
  end
end

def e5_state_typo(%Account.ID{} = id, %Context{} = context) do
  with {:ok, state} <- @repo.get(id, :current, context), do: state.nmae
end
```

```
warning: incompatible types given to Blind.Account.Repo.Pg.get/3:
    given types: dynamic(%Blind.Account.ID{}), -integer()-, dynamic(%Core.Context{})
    but expected one of: %Blind.Account.ID{}, %{..., __struct__: Core.Version} or :current, %Core.Context{}
└─ lib/scenarios/e_repo.ex:17:75: Blind.S.Repo.e2_int_version/2

warning: the following clause will never match:
    :ok ->
which has type: dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()})
└─ lib/scenarios/e_repo.ex:34: Blind.S.Repo.e4_case_get/2
```

- **Ловятся:**
  - E1 — чужой ID из паттерна;
  - E2 — `1`;
  - E2b — `"*"`;
  - E3c — одно событие вместо списка;
  - E4 — clause `:ok`;
  - E4b — `{:error, %Core.Error{code: :not_found}}`;
  - E7 — `refresh` чужого состояния.
- **Молчат:**
  - E1b — ID из `Order.ID.new()`, runtime `FunctionClauseError` `Account.Repo.Pg.get/4`;
  - E3 и E3b — не-событие или состояние в `append`: нужна БД. По коду падает `outbox.from_events` внутри
    транзакции [5:501]. Тот же шаг без транзакции: `Outbox.from_events(["bad"])` — `FunctionClauseError`
    `Blind.Codec.Internal.dump/1`, `from_events([%Account{}])` — `ArgumentError` «нет codec-плагина»;
  - E4 — clause `{:ok, {_events, state}}`: нужна БД, по коду `CaseClauseError`;
  - E5 — опечатка в поле состояния из `{:ok, state}`: нужна БД, по коду `KeyError`;
  - E6 — `get_many([{%Order.ID{}, :current}])`, runtime `FunctionClauseError` в `fn` из `initial_states!/2` до
    запроса [5:261-273];
  - E8 — clause `{:ok, _}` по результату `append`.
- **Причины:**
  - Домены взяты из головы `get`/`refresh`/`append` в `quote` [5:142-167].
  - Результат `get/refresh/get_many` — `{:ok, term()}`: состояние сворачивает `cfg.aggregate.fold` через
    переменную. Ошибка сужена до `code: :version_mismatch`. Единственное место с этим паттерном —
    `result_tag/1` [5:304, 481-482]; других `{:error, _}` у чтения нет.
  - Результат `append/2` — `dynamic()`: `Transact.run` — модуль того же проекта core [5:494].

## 6. `Agg.Process.execute`

```elixir
def f2_foreign_cmd(%Account.ID{} = id, %Order.Cmd.Place{} = cmd, %Context{} = context),
  do: Account.Process.execute(id, :current, cmd, context)
def f4_fun_arity2(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context),
  do: Account.Process.execute(id, :current, cmd, context, fn _events, _extra -> :ok end)
```

```
warning: incompatible types given to Blind.Account.Process.execute/5:
    given types: (dynamic(%Blind.Account.ID{}), :current, dynamic(%Blind.Account.Cmd.Open{}), dynamic(%Core.Context{}), -(term(), term() -> dynamic(:ok))-)
    but expected one of: (%Blind.Account.ID{}, %{..., __struct__: Core.Version} or :current, %{..., __struct__: atom()}, %Core.Context{}, nil or (none() -> term()))
└─ lib/scenarios/f_process.ex:24:25: Blind.S.Process.f4_fun_arity2/3
```

- **Ловятся:** F1 (чужой ID из паттерна), F3 (`1` вместо версии), F4 (колбэк арности 2), F6 (map в `opts`).
- **Молчат:**
  - F1b — ID из `Order.ID.new()`, runtime `FunctionClauseError` `Account.Process.execute/6`;
  - F2 — команда чужого агрегата: домен `is_struct(command)` [6:202]. Нужна БД. По коду внутри транзакции
    `cfg.aggregate.execute` → `FunctionClauseError` `Account.decide/2` [7:67]; при `enabled: true` процесс на id
    падает, вызывающему приходит exit [6:62-63];
  - F4b — колбэк возвращает `{:ok, events}`: нужна БД, по коду `CaseClauseError` до commit [7:87-92][6:35];
  - F4c — колбэк `fn %Opened{} -> :ok end` при списке событий: нужна БД, по коду `FunctionClauseError` в `fn`.
    Проверяется только арность [01 §10];
  - F5 — clause `{:ok, state}`: результат `dynamic()`, потому что `Core.Es.Aggregate.Process.execute/4` отдаёт
    результат замыкания `Otel.Es.execute` [6:254] [39]. В runtime ветка просто не срабатывает.

## 7. Проекция

```elixir
defmodule Blind.BadProjection do
  use Core.Es.Projection, name: "blind_bad", events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed]
  def project(%Account.Event.Opened{payload: payload}), do: store(payload.nmae)                                  # G3a
  def project(%Account.Event.Renamed{payload: %Account.Event.Renamed.Payload{} = payload}), do: store(payload.nmae) # G3b
  def project(%Order.Event.Placed{}), do: :ok                                                                     # G2
  # G1: нет clause для Account.Event.Closed
end
```

Выведенная сигнатура [39]:
`(%Opened{payload: %{..., nmae: term()}} or %Renamed{payload: %Renamed.Payload{}} -> dynamic(:ok))`,
`(%Blind.Order.Event.Placed{} -> :ok)`.

- **G1 — нет clause `project/1` для события из `events:`.**
  - Компиляция: сигнала нет. `__before_compile__` проверяет только наличие `project/1`/`clear/0` [8:220-234].
    Пачка зовёт `projection.project(event)` через переменную [8:batch.ex:202]. Клаузу проверяет тест
    `use Core.Es.ProjectionCase` [12:projection_case.ex:23-24].
  - Runtime через пачку: нужна БД. По коду `FunctionClauseError` становится `Logger.warning` и прикладной
    ошибкой `:projection_raised`, пачка откатывается [8:63-69].
  - Прямой `BadProjection.project(%Closed{})` ловится, runtime `FunctionClauseError`.
- **G2 — clause для события не из `events:`** молчит. Пачка такой тег не читает, clause не исполняется.
- **G3a — опечатка в поле нагрузки** молчит при определении, прямой вызов в runtime — `KeyError`. Прямой вызов с
  событием из `Opened.new/5` (G3c) ловится: домен сужен до `payload: %{..., nmae: term()}`, а у аргумента
  `%Opened.Payload{}` [01 §8].
- **G3b — та же опечатка при `%Payload{} = payload`** ловится при определении.
- **G4 (сверх списка) — `Core.Es.Projection.await/4`.** Сигнатура
  `(atom(), atom(), %{..., __struct__: atom()}, integer() -> dynamic())` [39].
  - `await(Blind.Projection, Account, %Order.ID{}, 100)` молчит. Нужна БД и дерево. По коду ошибки нет: ожидание
    идёт по потоку `account` с uuid заказа [9:26-36].
  - `await(Blind.Projection, Order, id, 100)` молчит, runtime `FunctionClauseError`
    `Core.Es.Projection.Await.subscribed_type/2` [9:42-46].
  - Clause `{:ok, _}` по результату молчит.
  - В qc `await` вызывается [22].

## 8. Кодек событий

```elixir
defmodule Blind.Parcel.Event.Codec do   # tags: Sent, Lost (с нагрузкой), Returned (без)
  use Core.Es.Event.Codec, event: Event, type: "parcel", tags: @tag_by_mod
  def dump_payload(%Event.Sent{payload: payload}, _codec), do: %{"note" => payload.note}  # H1: нет Lost
  def load_payload(Event.Sent, wire, _codec) when is_map(wire),                            # H1: нет Lost
    do: {:ok, %Account.Event.Renamed.Payload{name: field(wire, :note)}}                    # H2: чужая нагрузка
end

def h3a_family_typo(data) do
  {:ok, event} = InCodec.load(Account.Event, data)
  event.aggregat_id
end
```

- **H1 — нет clause `dump_payload/2`/`load_payload/3` для события с нагрузкой.** Молчит при определении и через
  фасад.
  - `__before_compile__` требует только наличия функций [4:248-263].
  - Приватная `es_dump_payload(%mod{} = event, codec)` зовёт `dump_payload` с аргументом «любой struct»
    [4:230-236]; домен пересекается.
  - Runtime: `InCodec.dump(%Lost{})` → `FunctionClauseError` `Parcel.Event.Codec.dump_payload/2`;
    `InCodec.load(Parcel.Event, wire)` → `FunctionClauseError` `load_payload/3`.
  - Прямые вызовы `dump_payload(%Lost{}, …)` и `load_payload(Parcel.Event.Lost, …)` ловятся.
- **H2 — `load_payload` возвращает нагрузку чужого модуля.** Молчит, хотя сигнатура её знает:
  `(Blind.Parcel.Event.Sent, map(), term() -> dynamic({:ok, %Blind.Account.Event.Renamed.Payload{}}))` [39]. Runtime
  — `FunctionClauseError` `Blind.Parcel.Event.Sent.new/6`: `build/3` зовёт `mod.new` через переменную
  [4:432-440].
- **H3 — `InCodec.load(Account.Event, data)` и опечатка в поле события** (H3a), в поле нагрузки после
  `load(Account.Event.Opened, …)` (H3b), clause `:ok ->` (H3c) — молчат. Runtime: H3a и H3b — `KeyError`, у H3c
  ветка не срабатывает.
  - `Blind.Codec.Internal.load/2` → `dynamic()`: clauses плагинов и фолбэк слились в
    `(atom() and not(Core.Outbox.Record, Core.Outbox.RecordError), term() -> dynamic())` [39].
  - Плагин — модуль того же проекта. `load/3` кодека идёт в `load_by_tag/5` → `module.load` через переменную
    [4:393-400].
  - H3d — `%Account.Event.Opened{} = event = InCodec.load!(…)` и `event.aggregat_id` — ловится
    [01 §6].
- **H4–H6 (сверх списка):**
  - `InCodec.dump("not a struct")` ловится;
  - `InCodec.load(Blind.Order.Cmd.Place, data)` молчит, runtime `ArgumentError` «нет codec-плагина». Фолбэк
    `load(mod, raw) when is_atom(mod)` [11:89-93] — catch-all [01 §1];
  - `InCodec.dump(%Account.Cmd.Open{})` молчит, runtime `ArgumentError`. Фолбэк `dump(%mod{})` [11:79-83];
  - `Account.Event.Codec.dump(%Order.Event.Cancelled{}, InCodec)` молчит, runtime `FunctionClauseError`
    `Account.Event.Codec.dump/2`. Guard `is_map_key(@es_tag_by_mod, mod)` домен не сужает: сигнатура — любой
    struct с полями события [4:200-202][39].

## 9. Команда

```elixir
def i1_by_foreign(%Account{} = state, %Account.Name{} = name, %Order.ID{} = by, %Es.Event.At{} = at),
  do: Account.execute(state, %Account.Cmd.Open{name: name, by: by, at: at})
```

- **Молчат** I1 (`by: %Order.ID{}`), I2 (`at: DateTime.utc_now()`), I3 (`name: "строка"`) и I4 (прямой
  `Account.decide/2` с `by` чужого Prim).
  - Типов полей у struct нет [01 «Поля struct»].
  - `Cmd.__after_compile__` проверяет только `by`/`at` в `@enforce_keys` [2:46-76].
- **Runtime:**
  - I1 и I2 — `FunctionClauseError` `Blind.Account.Event.Opened.new/6` внутри `execute`;
  - I3 — `FunctionClauseError` `Opened.Payload.new/1` внутри `decide`;
  - I4 — `{:ok, [...]}` без ошибки: `decide` не читает `by`.

## 10. Стиль `decide` из qc

В qc: `@mutations [...]` и `def decide(%mod{}, %__MODULE__{version: nil} = role) when mod in @mutations`
[15:115, 166, 173][19:135, 226-236]. Команда там не связывается с переменной, поля читаются у состояния
`%__MODULE__{}`.

```elixir
@mutations [Cmd.Rename, Cmd.Close]
def decide(%mod{} = cmd, %__MODULE__{version: nil}) when mod in @mutations, do: {:error, cmd.nmae}  # J1
def decide(%Cmd.Rename{} = cmd, %__MODULE__{}),
  do: {:ok, [{Event.Renamed, Event.Renamed.Payload.new(cmd.nmae)}]}                               # J2
def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed]}
```

```
warning: unknown key .nmae in expression:
    cmd.nmae
the given type does not have the given key: dynamic(%Blind.Account.Cmd.Rename{name: term(), by: term(), at: term()})
└─ lib/scenarios/j_qc_decide.ex:19:62: Blind.QcStyle.decide/2
```

- **J2** (`%Cmd.Rename{} = cmd`) ловится при определении.
- **J1** (`%mod{} = cmd when mod in @mutations`) молчит:
  - при определении: домен clause сужается до
    `%{..., __struct__: Blind.Account.Cmd.Close or Blind.Account.Cmd.Rename, nmae: term()}` [39] [01 §8];
  - через `execute`;
  - при прямом `QcStyle.decide(%Cmd.Close{}, %QcStyle{version: nil})`: clause 3 пересекается с аргументом.
- **Runtime** `QcStyle.execute(%QcStyle{version: nil}, %Cmd.Close{})` — `KeyError` в `Blind.QcStyle.decide/2`.

## 11. Сверх списка: путь вызова в usecase

- **X1.** `execute` через модуль-параметр, как `QC.Transact.execute_all/3` [18:72-80]. Вызов
  `execute_all(Account, %Order{}, [cmd])` молчит [01 §2]. Runtime — `FunctionClauseError`
  `Blind.Account.execute/2`.
- **X2.** `Account.Outbox.from_events(["bad"])` молчит: домен `list(term())`. Runtime — `FunctionClauseError`
  `Blind.Codec.Internal.dump/1`.
- **X3.** `Core.Es.Store.page_stream(Account.Event.Codec, %Order.ID{}, …)`, как история в qc [16:95], молчит:
  домен `%{..., __struct__: atom()}` [39]. Нужна БД. По коду вернётся пустая страница потока `account` с uuid
  заказа [14:326-351].
- **X4.** Состояние из `@order_repo.get` передано в `Account.execute` — молчит: `{:ok, term()}`. Нужна БД. По
  коду — `FunctionClauseError` `Account.execute/2`.
- **X5.** События `Account` в `@order_repo.append` — молчит. Нужна БД. `Order.Outbox.from_events(account_events)`
  проходит без ошибки. `Core.Es.Store.append(Order.Event.Codec, account_events, …)` без транзакции падает
  `FunctionClauseError` `Blind.Order.Event.Codec.type/1` [14:163].
- **X6–X8.** Чужой ID через `defp load(id, ctx)` (X6), внутри `Transact.run(Blind.DAO, fn -> … end)` (X7) и через
  публичную обёртку без паттерна в том же модуле (X8) — ловятся. Сообщение X8:
  `incompatible types given to x8_wrapper/2 … expected %Blind.Account.ID{}, %Core.Context{}`. В `ExCk` при этом
  `x8_wrapper/2` — `(term(), term() -> dynamic())` [39]. Локальный вызов при проверке видит сигнатуру
  удалённого вызова, экспорт — нет [01 «Тот же проект»].
- **X9.** Usecase в другом модуле:
  - `Usecase.get_typed(%Account.ID{} = id, ctx)` из контроллера с `%Order.ID{}` ловится;
  - `Usecase.get_untyped(id, ctx)` молчит: `(term(), term() -> dynamic())`. Runtime — `FunctionClauseError`
    `Account.Repo.Pg.get/4`;
  - `Usecase.open/3` возвращает `dynamic()`, поэтому clause `:ok` и `executed.nmae` у вызывающего молчат.

## Сводная таблица

«Нужна БД» — исход по коду, БД не поднималась.

| № | Сценарий | Компиляция | Runtime | Причина |
|---|---|---|---|---|
| A1 | `Agg.execute/2`: команда чужого агрегата | молчит | `FunctionClauseError` `Account.decide/2` | домен команды — любой struct с `by`/`at` [1:117, 148]; `decide` через переменную [1:150] [01 §4] |
| A2 | `execute`: команда без clause в `decide` | молчит | `FunctionClauseError` `Account.decide/2` | то же |
| A3 | `execute`: состояние чужого агрегата | ловится | — | `is_struct(state, __MODULE__)` → `%{..., __struct__: Account}` |
| A4a | `case`: `{:ok, events} when is_list(events)` | ловится | — | результат из сигнатуры `Core.Es.Aggregate.execute/3` [01 «Зависимость»] |
| A4b | `with {:ok, events}` → `append(events, ctx)` | ловится (в `append/2`) | — | `events` — `{term(), term()}`, домен `append` — список |
| A4c | `case`: `:ok ->` | ловится | — | то же, что A4a |
| A5a | опечатка в поле состояния из результата | молчит | `KeyError` | состояние — `term()`: `Enum.reduce` + `aggregate.evolve` [1:171-185] [01 §4, §10] |
| A5b | то же после `%Account{} = executed` | ловится | — | сужение на границе [01 §6] |
| A5c | опечатка в поле события из результата | молчит | `KeyError` | события — `term()` |
| A6 | struct без `by`/`at` вместо команды | ловится | — | паттерн `%{by:, at:}` зависимости в домене |
| A7 | map вместо struct команды | ловится | — | `is_struct(command)` |
| A-d1 | `decide/2`: чужая команда | ловится | — | clauses `decide` [01 «Сигнатура из clauses»] |
| A-d2 | `decide/2`: команда без clause | ловится | — | то же |
| A-d3 | `decide/2`: чужое состояние | ловится | — | то же |
| A-d4 | `case` по `decide`: `{:ok, {events, state}}` | ловится | — | результат clauses |
| A-d5 | опечатка в поле нагрузки из результата `decide` | молчит | `KeyError` | `Payload.new/1` того же проекта → `term()` [01 «Тот же проект»] |
| B1 | `decide` → модуль события не из `tags:` | молчит | `FunctionClauseError` `Core.Es.Aggregate.event/6` | результат `decide` ни с чем не сверяется; `aggregate.decide`, `mod.new` через переменную [1:150, 215-219] |
| B2 | `decide` → `{Event.A, %Event.B.Payload{}}` | молчит | `FunctionClauseError` `Opened.new/6` | то же |
| B3 | `decide` → голый модуль события с нагрузкой | молчит | `UndefinedFunctionError` `Opened.new/4` | то же |
| B4, B5 | B1, B3 прямым `Agg.fold/3` | молчит | как B1, B3 | домен `results` — `list(term())` |
| C1 | нет clause `evolve` для события из `tags:` | молчит (сигнала нет) | `FunctionClauseError` `BadEvolve.evolve/2` | `aggregate.evolve` через переменную [1:185]; нет исчерпываемости [01 §9]; ловит тест `EventCompatCase` [12] |
| C1d | то же, прямой `evolve/2` | ловится | — | clauses `evolve` |
| C2a | опечатка в поле нагрузки в `evolve` | молчит | `KeyError` | поле в паттерне struct — `term()` [01 «Поля struct»] |
| C2b | то же при `payload: %Payload{} = payload` | ловится | — | паттерн нагрузки |
| C3 | `Agg.fold(state, ["bad"])` | молчит | `FunctionClauseError` `Core.Es.Aggregate.step/3` | домен `fold/2` — `list(term())` [01 §10] |
| C3d | `Agg.evolve(state, "bad")` | ловится | — | clauses `evolve` |
| C4 | опечатка в ключе `%{state \| nmae: …}` в `evolve` | молчит | `KeyError` | `state` без паттерна; вызов через переменную |
| C5 | `Agg.fold` с событием чужого агрегата | молчит | `ArgumentError` «событие чужого агрегата» | `list(term())`; проверка `aggregate_id` в `step/3` [1:189-193] |
| D1, D1b, D1c | `Event.new`: чужая нагрузка / map | ловится | — | паттерн `%Payload{}` в голове `new` [3:151-161] |
| D2, D2c | `Event.new`: чужой Prim в `aggregate_id` (паттерн, `{:ok, id} = new(raw)`) | ловится | — | паттерн `%Agg.ID{}` |
| D2b | то же, ID из `Order.ID.new()` | молчит | `FunctionClauseError` `Opened.new/6` | `new/0` → `dynamic()` через `Result.unwrap!/1` [10] |
| D3 | `Event.new`: чужой Prim в `by` | ловится | — | паттерн `%By{}` |
| D3b | то же из `Order.ID.new()` | молчит | `FunctionClauseError` `Opened.new/6` | как D2b |
| D4, D4b | `Event.new`: `DateTime` вместо `At`, целое вместо `Version` | ловится | — | паттерны `%At{}`, `%Version{}` |
| D5 | опечатка в поле события из `new/4` | ловится | — | результат `new` — известный struct |
| E1 | `repo.get`: чужой ID из паттерна | ловится | — | `%unquote(cfg.id){}` [5:142] |
| E1b | `repo.get`: чужой ID из `Order.ID.new()` | молчит | `FunctionClauseError` `Account.Repo.Pg.get/4` | как D2b |
| E2, E2b | `repo.get`: `1` / `"*"` вместо версии | ловится | — | `is_version` → `%{..., __struct__: Version} or :current` [10] |
| E3, E3b | `repo.append`: не-событие / состояние | молчит | нужна БД; по коду `FunctionClauseError` `InCodec.dump/1` / `ArgumentError` в `outbox.from_events` | `is_list(events)` [5:154] |
| E3c | `repo.append`: событие без списка | ловится | — | `is_list(events)` |
| E4 | `case get`: `:ok ->` | ловится | — | результат `get/5` зависимости |
| E4 | `case get`: `{:ok, {events, state}}` | молчит | нужна БД; по коду `CaseClauseError` | `{:ok, term()}` |
| E4b | `case get`: `{:error, %Error{code: :not_found}}` | ловится | — | ошибка сужена `result_tag/1` [5:304, 481-482] |
| E5 | опечатка в поле состояния из `{:ok, state}` | молчит | нужна БД; по коду `KeyError` | `{:ok, term()}`: свёртка через `cfg.aggregate.fold` |
| E6 | `get_many` с чужим ID | молчит | `FunctionClauseError` в `fn` `initial_states!/2` | `is_list(pairs)` [5:148] |
| E7 | `refresh` чужого состояния | ловится | — | `%unquote(cfg.aggregate){}` [5:160-167] |
| E8 | `case append`: `{:ok, _}` | молчит | ветка не срабатывает | результат `append/2` — `dynamic()` [5:494] |
| F1 | `Process.execute`: чужой ID из паттерна | ловится | — | `%unquote(id){}` [6:194-203] |
| F1b | то же из `Order.ID.new()` | молчит | `FunctionClauseError` `Account.Process.execute/6` | как D2b |
| F2 | `Process.execute`: команда чужого агрегата | молчит | нужна БД; по коду `FunctionClauseError` `Account.decide/2` в транзакции | `is_struct(command)` [6:202]; `cfg.aggregate.execute` [7:67] |
| F3 | `Process.execute`: целое вместо версии | ловится | — | `is_version` |
| F4 | колбэк арности 2 | ловится | — | `is_function(fun, 1)` [01 §10] |
| F4b | колбэк возвращает не `:ok \| {:error, _}` | молчит | нужна БД; по коду `CaseClauseError` [7:87-92] | у параметра-функции только арность [01 §10] |
| F4c | колбэк с паттерном одного события | молчит | нужна БД; по коду `FunctionClauseError` в `fn` | то же |
| F5 | `case Process.execute`: `{:ok, state}` | молчит | ветка не срабатывает | результат `dynamic()`: замыкание `Otel.Es.execute` [6:254] |
| F6 | `opts` не список | ловится | — | `is_list(opts)` |
| G1 | нет clause `project/1` для события из `events:` | молчит (сигнала нет) | нужна БД; по коду `:projection_raised`, откат пачки [8:63-69] | `projection.project` через переменную [8:batch.ex:202]; ловит тест `ProjectionCase` [12] |
| G1d | то же, прямой `project/1` | ловится | — | clauses `project` |
| G2 | clause для события не из `events:` | молчит | не исполняется | лишняя clause расширяет домен |
| G3a | опечатка в поле нагрузки в `project/1` | молчит | `KeyError` (прямой вызов); через пачку — нужна БД | поле struct — `term()` |
| G3b | то же при `%Payload{} = payload` | ловится | — | паттерн нагрузки |
| G3c | прямой `project/1` с событием из `new/5` при опечатке G3a | ловится | — | домен сужен `payload.nmae` [01 §8] |
| G4 | `await/4`: чужой ID | молчит | нужна БД и дерево; по коду без ошибки | домен `%{..., __struct__: atom()}` |
| G4b | `await/4`: агрегат не из `events:` | молчит | `FunctionClauseError` `Await.subscribed_type/2` | домен `atom()` [9:26-46] |
| G4c | `case await`: `{:ok, _}` | молчит | ветка не срабатывает | результат `dynamic()` |
| H1 | нет clause `dump_payload`/`load_payload` для события с нагрузкой | молчит | `FunctionClauseError` `Parcel.Event.Codec.dump_payload/2` / `load_payload/3` | `__before_compile__` — только наличие [4:248-263]; `es_*_payload(%mod{})` [4:230-236] |
| H1d | прямой `dump_payload`/`load_payload` для `Lost` | ловится | — | clauses кодека |
| H2 | `load_payload` → нагрузка чужого модуля | молчит | `FunctionClauseError` `Parcel.Event.Sent.new/6` | `build/3` → `mod.new` через переменную [4:432-440] |
| H3a, H3b | `InCodec.load(Agg.Event \| Event.Mod, data)` + опечатка | молчит | `KeyError` | фасад `load/2` → `dynamic()` [11:54-60, 89-93][4:398] |
| H3c | `case InCodec.load`: `:ok ->` | молчит | ветка не срабатывает | то же |
| H3d | `%Opened{} = event = InCodec.load!(…)` + опечатка | ловится | — | сужение на границе [01 §6] |
| H4 | `InCodec.dump("not a struct")` | ловится | — | домен `dump/1` — struct |
| H4b | `InCodec.load(модуль без плагина, data)` | молчит | `ArgumentError` «нет codec-плагина» | фолбэк `load(mod, raw) when is_atom(mod)` [01 §1] |
| H5 | `Agg.Event.Codec.dump(событие другого кодека)` | молчит | `FunctionClauseError` `Account.Event.Codec.dump/2` | `is_map_key(@es_tag_by_mod, mod)` не сужает домен |
| H6 | `InCodec.dump(%Cmd{})` | молчит | `ArgumentError` «нет codec-плагина» | фолбэк `dump(%mod{})` [11:79-83] |
| I1, I2 | команда: `by`/`at` не того Prim | молчит | `FunctionClauseError` `Opened.new/6` | поля struct без типов [01 «Поля struct»]; `mod.new` через переменную |
| I3 | команда: поле не Prim | молчит | `FunctionClauseError` `Opened.Payload.new/1` | то же |
| I4 | прямой `decide` с `by` не того Prim | молчит | без ошибки: `{:ok, [...]}` | `decide` не читает `by` |
| J1 | `%mod{} = cmd when mod in @mutations` + опечатка | молчит | `KeyError` `QcStyle.decide/2` | открытая map, домен сужен до `nmae: term()` [01 §8] |
| J2 | `%Cmd.Rename{} = cmd` + опечатка | ловится | — | закрытый struct |
| X1 | `aggregate.execute(state, cmd)` с модулем-параметром | молчит | `FunctionClauseError` `Account.execute/2` | [01 §2] |
| X2 | `Outbox.from_events(["bad"])` | молчит | `FunctionClauseError` `InCodec.dump/1` | `is_list(events)` |
| X3 | `Store.page_stream` кодеком одного агрегата и ID другого | молчит | нужна БД; по коду пустая страница | `%_{} = aggregate_id` [14:326-332] |
| X4 | состояние из репозитория другого агрегата → `Agg.execute` | молчит | нужна БД; по коду `FunctionClauseError` `Account.execute/2` | `{:ok, term()}` |
| X5 | события агрегата A в `append` репозитория B | молчит | нужна БД; шаг `Store.append` — `FunctionClauseError` `Order.Event.Codec.type/1` | `is_list(events)` |
| X6–X8 | чужой ID через `defp`, замыкание, обёртку в том же модуле | ловится | — | локальный вызов и захват переменной |
| X9 | чужой ID через usecase другого модуля без паттерна | молчит | `FunctionClauseError` `Account.Repo.Pg.get/4` | экспорт обёртки — `(term(), term() -> dynamic())` [01 «Тот же проект»] |
| X9c | результат usecase другого модуля: `:ok` / опечатка | молчит | — (нужна БД) | результат `dynamic()` |

## Выведенные сигнатуры

Сгенерированные функции потребителя — `Blind.Account` и его модули [39]:

| Функция | Сигнатура |
|---|---|
| `Account.__es_event_codec__/0` | `( -> Blind.Account.Event.Codec)` |
| `Account.fold/2` | `(%{..., __struct__: Blind.Account}, list(term()) -> dynamic())` |
| `Account.fold/3` | `(%{..., __struct__: Blind.Account, version: term()}, %{..., __struct__: atom(), at: term(), by: term()}, list(term()) -> dynamic())` |
| `Account.execute/2` | `(%{..., __struct__: Blind.Account}, %{..., __struct__: atom(), at: term(), by: term()} -> dynamic({:error, %Core.Error{}} or {:ok, {term(), term()}}))` |
| `Account.Cmd.Open.__es_cmd__/0` | `( -> true)` |
| `Account.Event.Opened.new/5` | `(%Opened.Payload{}, %Account.ID{}, %Core.Version{}, %Blind.UserID{}, %Core.Es.Event.At{} -> dynamic(%Opened{payload: %Opened.Payload{}, aggregate_id: %Account.ID{}, aggregate_version: %Core.Version{}, at: %Core.Es.Event.At{}, by: %Blind.UserID{}}))` |
| `Account.Event.Opened.new/6` | то же и `%{..., __struct__: Core.Es.Event.ID} or nil` |
| `Account.Event.Closed.new/4`, `new/5` | `(%Account.ID{}, %Core.Version{}, %Blind.UserID{}, %Core.Es.Event.At{}[, ID or nil] -> dynamic(%Closed{payload: nil, …}))` |
| `Account.Event.Opened.__es_payload__/0`, `__es_aggregate_id__/0`, `__es_by__/0` | `( -> Opened.Payload)`, `( -> Blind.Account.ID)`, `( -> Blind.UserID)` |
| `Account.Event.Codec.__es_type__/0` | `( -> binary())` |
| `Account.Event.Codec.__es_mods__/0`, `__codec_types__/0` | `( -> non_empty_list(Closed or Opened or Renamed))` |
| `Account.Event.Codec.__es_aggregate_id__/0`, `__codec_union__/0` | `( -> Blind.Account.ID)`, `( -> Blind.Account.Event)` |
| `Account.Event.Codec.type/1` | `(%{..., __struct__: atom()} -> dynamic())`, `(atom() -> binary())` |
| `Account.Event.Codec.mod_by_tag/1` | `(binary() -> dynamic(:error or {:ok, Closed or Opened or Renamed}))` |
| `Account.Event.Codec.dump/2` | `(%{..., __struct__: atom(), aggregate_id: term(), aggregate_version: term(), at: term(), by: term(), id: term()}, atom() -> dynamic(%{binary() => term()}))` |
| `Account.Event.Codec.load/3` | `(Blind.Account.Event, term(), atom() -> dynamic())`, `(not Blind.Account.Event, map(), atom() -> dynamic())` |
| `Blind.Codec.Internal.dump/1` | 3 clauses: `%Core.Outbox.Record{}`, `%Core.Outbox.RecordError{}`, объединение событий плагинов `or (%{..., __struct__: atom()} and not …) -> dynamic()` |
| `Blind.Codec.Internal.load/2` | `(Core.Outbox.Record, map() -> …)`, `(Core.Outbox.RecordError, map() -> dynamic())`, `(atom() and not(Record, RecordError), term() -> dynamic())` |
| `Blind.Codec.Internal.load!/2` | `(atom(), term() -> dynamic())` |
| `Account.Outbox.from_events/1` | `(list(term()) -> dynamic({:error or :ok, term()}))` |
| `Account.Outbox.__es_event__/0` | `( -> Blind.Account.Event)` |
| `Account.Repo.__es_aggregate_repo__/0` | `( -> %{aggregate: Blind.Account, id: Blind.Account.ID})` |
| `Account.Repo.Pg.get/3` (`get/4` + `list(term())`) | `(%Account.ID{}, %{..., __struct__: Core.Version} or :current, %Core.Context{} -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` |
| `Account.Repo.Pg.get_many/2` (`/3`) | `(list(term()), %Core.Context{} -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` |
| `Account.Repo.Pg.append/2` (`/3`) | `(list(term()), %Core.Context{} -> dynamic())` |
| `Account.Repo.Pg.refresh/3` (`/4`) | `(%Blind.Account{}, %{..., __struct__: Core.Version} or :current, %Core.Context{} -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` |
| `Account.Process.execute/4` | `(%Account.ID{}, %{..., __struct__: Core.Version} or :current, %{..., __struct__: atom()}, %Core.Context{} -> dynamic())` |
| `Account.Process.execute/5`, `/6` | то же и `nil or (none() -> term())`[, `list(term())`] `-> dynamic()` |
| `Account.Process.child_spec/1` | `(list(term()) -> dynamic(%{id: atom(), start: {Core.Es.Aggregate.Process, :start_link, non_empty_list(term())}, type: :supervisor}))` |
| `Account.Process.watch_list/1` | `(list(term()) -> dynamic(list(%{component: binary(), name: atom()})))` |
| `Account.Process.__es_aggregate_process__/0` | `( -> %{aggregate: Blind.Account, registry: …Registry, repo: Blind.Account.Repo.Pg, supervisor: …Supervisor, type: binary()})` |
| `Projection.__es_projection__/0` | `( -> dynamic())` |
| `Projection.project/1` (написан автором) | `(%Opened{payload: %{..., name: %Account.Name{}}} or %Renamed{…} -> dynamic(:ok))`, `(%Closed{} -> :ok)` |
| `Projection.clear/0` | `( -> :ok)` |

Функции `Core.*`, в которые пересылается вызов, — как их видит потребитель [39]:

| Функция | Сигнатура |
|---|---|
| `Core.Es.Aggregate.execute/3` | `(atom(), %{..., __struct__: term()}, %{..., __struct__: atom(), at: term(), by: term()} -> dynamic({:error, %Core.Error{}} or {:ok, {term(), term()}}))` |
| `Core.Es.Aggregate.fold/3` | `(atom(), %{..., __struct__: term()}, list(term()) -> dynamic())` |
| `Core.Es.Aggregate.fold/4` | `(atom(), %{..., __struct__: term(), version: term()}, %{..., __struct__: atom(), at: term(), by: term()}, list(term()) -> dynamic())` |
| `Core.Es.Aggregate.events/5` | `(atom(), %{..., __struct__: term(), version: term()}, list(term()), term(), term() -> dynamic())` |
| `Core.Es.Aggregate.Repo.Pg.get/5` | `(%{..., aggregate: %{..., __struct__: atom()} or atom(), snapshot: %{..., every: term()} or nil, type: term()}, term(), %{..., __struct__: Core.Version} or :current, %Core.Context{}, list(term()) -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` |
| `Core.Es.Aggregate.Repo.Pg.get_many/4` | `(%{..., aggregate: term(), id: term(), snapshot: …, type: term()}, list(term()), %Core.Context{}, list(term()) -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` |
| `Core.Es.Aggregate.Repo.Pg.append/4` | `(term(), empty_list(), %Core.Context{}, list(term()) -> :ok)`, `(%{..., dao: term()}, non_empty_list(term()), %Core.Context{}, list(term()) -> dynamic())` |
| `Core.Es.Aggregate.Repo.Pg.refresh/5` | `(%{..., snapshot: …, type: term()}, term(), %{..., __struct__: Core.Version} or :current, %Core.Context{}, list(term()) -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, term()}))` |
| `Core.Es.Aggregate.Process.execute/4` | `(atom(), %{..., type: term()}, %{..., command: %{..., __struct__: term()}, id: term()}, list(term()) -> dynamic())` |
| `Core.Es.Aggregate.Process.child_spec/3`, `watch_list/3` | `(atom(), term(), list(term()) -> dynamic(…))` — формы как у `child_spec/1`, `watch_list/1` |
| `Core.Es.Event.Codec.dump_envelope/4` | `(%{..., aggregate_id: term(), aggregate_version: term(), at: term(), by: term(), id: term()}, binary(), term(), atom() -> dynamic(%{binary() => term()}))` |
| `Core.Es.Event.Codec.load_by_tag/5` | `(map(), map(), map(), term(), term() -> dynamic())`, `(not map(), map(), map(), term(), term() -> dynamic({:error, term()}))` |
| `Core.Es.Event.Codec.build/3` | `(atom(), term(), map() -> dynamic())` |
| `Core.Es.Event.Codec.to_fields/1` | `(map() -> dynamic(%{aggregate_id: term(), …, type: term()}))` |
| `Core.Es.Projection.await/4` | `(atom(), atom(), %{..., __struct__: atom()}, integer() -> dynamic())` |
| `Core.Es.Projection.run_once/2` | `(atom(), list(term()) -> dynamic(:idle or :locked or :outdated or :processed or {:error, %Core.Error{}}))` |
| `Core.Es.Projection.Await.run/5` | `(atom(), %{..., codec: atom(), dao: atom(), name: term(), streams: map()}, atom(), %{..., __struct__: atom()}, integer() -> dynamic())` |
| `Core.Es.Store.page_stream/5` | `(atom(), %{..., __struct__: atom()}, %Core.Pagination.Limit{}, %Core.Pagination.Offset{}, %Core.Context{} -> dynamic())` |
| `Core.Result.unwrap!/1` | `({:ok, term()} -> dynamic())`, `({:error, term()} -> none())` |
| `Core.Result.traverse/2` | `(list(term()), (none() -> term()) -> dynamic({:error or :ok, term()}))` |
| `Account.ID.new/0`, `Account.Name.new!/1`, `Core.Version.new/0`, `Core.Es.Event.At.now!/0` | `( -> dynamic())` / `(term() -> dynamic())` |
| `Account.ID.new/1` | `(term() -> dynamic({:error, term()} or {:ok, %Blind.Account.ID{}}))` |
| `Core.Es.Event.At.now/0` | `( -> dynamic({:error, term()} or {:ok, %Core.Es.Event.At{}}))` |

`list(term())` — сокращение `empty_list() or non_empty_list(term(), term())`.

## Не найдено / не проверено

- **Исходы, требующие транзакции `Blind.DAO`,** указаны по коду, БД не поднималась: E3, E4 (`{:ok, {…}}`), E5, F2,
  F4b, F4c, G1 и G3a через пачку, G4, X3, X4, X5, X9c. Шаг до транзакции проверен отдельно у E3 и X5.
- **Режим `enabled: true` процесса агрегата** (исключение → exit вызывающему) не запускался, исход взят из
  `@moduledoc` [6:62-63].
- **Git-зависимость, как в qc,** не проверялась, только `path:`. `infer_signatures` берёт все зависимости с
  `app: true` [01 «Не найдено»].
- **Код qc не компилировался.** Выводы о qc — по его исходникам на core `v0.2.1` и эксперименту на HEAD core-ex.
- **Тесты потребителя** (`mix test`, `infer_signatures: false`) не собирались.
- **Сравнение с «тем же проектом»** сделано по `_build/test` core-ex от 2026-09-15: сборка старше HEAD,
  перекомпиляция core-ex не выполнялась.
- **Не выяснена причина** `CompileError` `Core.Config.repo!(Blind.Order.Repo): реализация Blind.Order.Repo.Pg
  недоступна (:unavailable)` из `lib/scenarios/x_extra.ex`. Ошибка была, пока все модули `Blind.Order` лежали в
  одном файле `lib/blind/order.ex`, и исчезла после разнесения по файлам.

## Источники

core-ex, HEAD 47f692f (`/home/aleksey/Projects/core-ex`):

1. `lib/core/es/aggregate.ex:78-82, 104-118, 125-140, 148-158, 163-172, 176-193, 200-219`
2. `lib/core/es/cmd.ex:46-76`
3. `lib/core/es/event.ex:108-128, 149-170`
4. `lib/core/es/event/codec.ex:180-184, 200-202, 213-224, 229-241, 248-263, 393-400, 432-440`
5. `lib/core/es/aggregate/repo/pg.ex:142-169, 242-257, 261-273, 296-309, 481-482, 489-505`
6. `lib/core/es/aggregate/process.ex:35, 62-63, 194-206, 242-257`
7. `lib/core/es/aggregate/process/execution.ex:58-74, 87-92`
8. `lib/core/es/projection.ex:63-69, 181, 220-234, 414-416`; `lib/core/es/projection/batch.ex:88, 202`
9. `lib/core/es/projection/await.ex:26-46`
10. `lib/core/prim.ex:70, 100`; `lib/core/prim/uuid.ex:57`; `lib/core/result.ex:121-124`; `lib/core/version.ex:24-25`
11. `lib/core/codec/facade.ex:46-60, 79-101`
12. `lib/core/es/event_compat_case.ex:29-31`; `lib/core/es/projection_case.ex:23-24`
13. `test/support/es_fixture/**` — образец потребителя; `config/test.exs`, `test/test_helper.exs` — конфигурация
14. `lib/core/es/store.ex:138-163, 326-356`; `lib/core/config.ex:83-110`; `lib/core/es/outbox.ex:60-69`

quality-control-back (`/home/aleksey/Projects/quality-control-back`, core `v0.2.1`):

15. `lib/qc/domain/perms/common/role.ex:115, 153-196, 210-234`
16. `lib/qc/domain/perms/admin/usecases/role.ex:35, 95, 172-205`
17. `lib/qc/domain/users/admin/usecases/user.ex:41, 150-180`
18. `lib/qc/transact.ex:54-58, 72-80`
19. `lib/qc/domain/users/common/user.ex:135, 216-251`
20. `lib/qc/domain/users/common/projection.ex:24-58`
21. `lib/qc/domain/perms/common/role/event/codec.ex:25-75`
22. `lib/qc_web/helper/projection.ex:41`; `lib/qc/domain/notifications/common/rules/source.ex:47, 57`
23. `mix.exs:51-56`

Эксперименты — в `02-experiments/`
(далее `…/`):

24. `…/mix.exs`, `…/config/config.exs`, `…/mix.lock` — сборка потребителя
25. `…/lib/blind/**` — базовый потребитель: `account*`, `order*`, `parcel.ex`, `projection.ex`, `codec.ex`, `dao.ex`, `user_id.ex`
26. `…/lib/scenarios/a_execute.ex` — A1–A7, A-d1–A-d5
27. `…/lib/scenarios/b_decide_result.ex` — B1–B5
28. `…/lib/scenarios/c_evolve.ex` — C1–C4
29. `…/lib/scenarios/d_event_new.ex` — D1–D5
30. `…/lib/scenarios/e_repo.ex` — E1–E8
31. `…/lib/scenarios/f_process.ex` — F1–F6
32. `…/lib/scenarios/g_projection.ex` — G1–G4
33. `…/lib/scenarios/h_codec.ex` и `…/lib/blind/parcel.ex` — H1–H6
34. `…/lib/scenarios/i_cmd.ex` — I1–I4
35. `…/lib/scenarios/j_qc_decide.ex` — J1, J2
36. `…/lib/scenarios/x_extra.ex`, `…/lib/scenarios/y_cross_module.ex` — X1–X9
37. `…/compile.out` — `mix compile --force`, 47 предупреждений
38. `…/runtime.exs`, `…/runtime_results.out` — runtime-исходы без БД (C5, H6 — там же)
39. `…/sig.exs`; `…/sigs_aggregate.out`, `…/sigs_repo_process.out`, `…/sigs_codec_proj.out`, `…/sigs_scenarios.out`
40. `…/sigs_core_same_project.out` — сигнатуры `Core.EsFixture.*` из `_build/test` core-ex
41. `.scratch/es-type-safety/research/01-elixir-1-20-type-system.md`
