# RESULTS · Типобезопасность `Core.Es`: прототип решений 1–5

Elixir 1.20.3 / OTP 29, core-ex 47f692f + правки worktree. Фикстура — `consumer/` (`:blind`, path-зависимость).
Коды сценариев — `../research/02-core-es-blind-spots.md`. Полный вывод — `out/`.

## Правки в `lib/` и `test/support/`

```
 lib/core/es/aggregate.ex                     | 45 ++++++++-----
 lib/core/es/aggregate/process.ex             | 11 +++-
 lib/core/es/aggregate/repo.ex                | 16 +++++
 lib/core/es/aggregate/repo/pg.ex             | 34 +++++++---
 lib/core/es/event/codec.ex                   | 99 +++++++++++++++++++++++++++-
 lib/core/es/projection.ex                    | 15 ++++-
 lib/core/prim.ex                             |  8 ++-
 lib/core/prim/date_time.ex                   |  7 +-
 test/support/es_fixture/account.ex           |  8 +--
 test/support/es_fixture/broken_projection.ex |  4 ++
```

| Файл | Суть |
|---|---|
| `aggregate.ex` | `quote generated: true`; головы `%__MODULE__{}`; `execute/2` зовёт `decide(command, state)` локально и сужает результат `case`; `fold/2,3` сужают `%__MODULE__{}`; в библиотеке новая `apply_decision/4` (старая `execute/3` оставлена) |
| `repo/pg.ex` | `quote generated: true`; `get`/`refresh` сужают `{:ok, %Agg{}}`, `get_many` — `{:ok, list}`, `append` — `:ok \| {:error, _}` |
| `process.ex` | результат `execute/4..6` через приватную `es_executed/1` из `quote generated: true`: `:ok \| {:error, _}` |
| `prim.ex`, `prim/date_time.ex` | `new!/1`, `now!/0`: `case` + `raise Core.Exc` вместо `Result.unwrap!/1` |
| `event/codec.ex` | `__before_compile__`: генерация `draft/1` + `CompileError` на общий модуль нагрузки; функции-проверки `dump_payload/2`, `load_payload/3`; `event_pattern/2`, `check_name/2`; `@es_use_line` |
| `aggregate/repo.ex` | функции-проверки `evolve/2` на каждое событие кодека (кодек грузится на компиляции) |
| `projection.ex` | `__before_compile__`: функции-проверки `project/1` по `events:`; `@es_use_line` |
| `es_fixture/account.ex` | `decide` через `Event.Codec.draft/1` |
| `es_fixture/broken_projection.ex` | пропуск `Closed` спрятан от новой проверки guard'ом, ложным только в runtime (иначе core-ex не собирается) |

Проверки core-ex: `MIX_ENV=test mix compile --warnings-as-errors` и `mix compile --warnings-as-errors` — чисто;
`mix test test/core/es` — 350 passed; `mix test` — 1329 passed, 2 excluded; `mix xref graph --format cycles
--fail-above 0` — No cycles found; `mix format --check-formatted` — чисто.

## P0 · Граница типов и локальный `decide`

**Ответ.** Решения 1–2 работают на настоящих макросах: A1, A2, A5a, E5, D2b, E1b, F1b, F5 ловятся, ложных предупреждений
у корректного потребителя нет. Слепым остаётся F2 (чужая команда в `Agg.Process.execute`): модуль процесса не видит
`decide` агрегата. Две поправки к форме сужения обязательны — ниже.

```elixir
quote generated: true do
  def execute(%__MODULE__{} = state, command) when is_struct(command) do
    case Core.Es.Aggregate.apply_decision(__MODULE__, state, command, decide(command, state)) do
      {:ok, {events, %__MODULE__{} = executed}} when is_list(events) -> {:ok, {events, executed}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

| Код | Сценарий | Было | Стало | Сообщение |
|---|---|---|---|---|
| A1 | `Account.execute` с `%Order.Cmd.Place{}` | молчит | ловится | `incompatible types given to Blind.Account.execute/2` |
| A2 | команда без clause в `decide` | молчит | ловится | то же |
| A1′ | чужая команда у `AlwaysFails` (`decide` только ошибка) | молчит | ловится | `…AlwaysFails.execute/2` |
| A5a | `executed.nmae` из `{:ok, {_, executed}}` | молчит | ловится | `unknown key .nmae` |
| A5a′ | то же у `NeverFails` (`decide` без ошибок) | молчит | ловится | `unknown key .nmae` |
| E5 | `state.nmae` из `{:ok, state} <- @repo.get` | молчит | ловится | `unknown key .nmae` |
| E5b | то же у `refresh` | молчит | ловится | `unknown key .nmae` |
| D2b | `Opened.new(payload, Order.ID.new(), …)` | молчит | ловится | `incompatible types given to …Opened.new/5` |
| E1b | `@repo.get(Order.ID.new(), …)` | молчит | ловится | `incompatible types given to …Repo.Pg.get/3` |
| F1b | `Process.execute(Order.ID.new(), …)` | молчит | ловится | `incompatible types given to …Process.execute/4` |
| F5 | `case Process.execute` с `{:ok, state} ->` | молчит | ловится | `the following clause will never match` |
| E8 | `case @repo.append` с `{:ok, _} ->` | молчит | ловится | то же |
| — | `Es.Event.At.now!().valeu`, `Version.new().valeu` | молчит | ловится | `unknown key .valeu` |
| F2 | `Process.execute` с чужой командой | молчит | **молчит** | домен `command` — `%{..., __struct__: atom()}` |
| A3, A4a | чужое состояние; `{:ok, events} when is_list` | ловилось | ловится | без изменений |

Сигнатуры после правок (`out/p0_p1_sigs.out`):

```
Blind.Account:execute/2
  (%Blind.Account{}, %Cmd.Close{} or %Cmd.Freeze{} or %Cmd.Open{} or %Cmd.Rename{} or
     %{..., __struct__: Cmd.Close or Cmd.Freeze or Cmd.Rename}
   -> dynamic({:error, %Core.Error{}} or {:ok, {list(term()), %Blind.Account{}}}))
Blind.NeverFails:execute/2  (… -> dynamic({:error, term()} or {:ok, {list(term()), %Blind.NeverFails{}}}))
Blind.Account.Repo.Pg:get/3 (… -> dynamic({:error, %Core.Error{code: :version_mismatch}} or {:ok, %Blind.Account{}}))
Blind.Account.Process:execute/4 (… -> dynamic(:ok or {:error, term()}))
Blind.Account.ID:new/0 ( -> dynamic(%Blind.Account.ID{}))      Core.Version:new/0 ( -> dynamic(%Core.Version{}))
```

Домен команды в стиле qc (`%command{} when command in @on_existing`) — открытая map с `__struct__` из списка, чужая
команда с ней не пересекается и ловится.

**Ложные предупреждения — нет.** Корректный потребитель `lib/blind/**`: `Account` (qc-стиль, `fold/3`, два события одной
командой), `NeverFails`, `AlwaysFails`, `Ping` (кодек без нагрузки), `User` (clauses `QC…User.decide`), `Usecase` (все
генерируемые функции в типовых вызовах) — 0 предупреждений (`out/final_compile.out`).

Без `generated: true` три ложных (`out/p0_without_generated.out`) — подтверждение решения 1:

```
warning: the following clause will never match:
    {:error, reason} ->
because it attempts to match on the result of:
    Core.Es.Aggregate.apply_decision(Blind.Ping, state, command, decide(command, state))
which has type:
    dynamic({:ok, {term(), term()}})
└─ lib/blind/ping.ex:6: Blind.Ping.execute/2
```

(то же у `NeverFails` и, для clause `{:ok, …}`, у `AlwaysFails`).

**Находки.**

1. **Недостижимая clause отдаёт `dynamic()`.** С `{:error, _} = error -> error` у `NeverFails` результат `execute/2` был
   `dynamic()`: тело недостижимой clause типизируется как `dynamic()`, и объединение схлопывается на корне. Чинит
   `{:error, reason} -> {:error, reason}` — `dynamic({:error, term()})` не съедает статическую часть. Правило для всех
   сужений в `generated`-коде: в clause, которая у части потребителей недостижима, не возвращать голую переменную.
2. **`new!/0`, `now!/0` ядра** остались бы `dynamic()` даже после `case`: `Result.unwrap!/1` — модуль того же проекта
   при сборке core, его результат при выводе — `dynamic()`, и объединение `%Prim{} or dynamic()` = `dynamic()`. У
   Prim потребителя `unwrap!` — зависимость (`none()` на ошибке), поэтому там работало. Чинит `raise Core.Exc, error`.
3. **`BrokenProjection` core-ex** — намеренно сломанная фикстура `ProjectionCase` — стала ловиться проверкой P2 и валит
   `--warnings-as-errors`. Пропуск спрятан guard'ом `when map_size(event) < 0`: `FunctionClauseError` бросает по-прежнему
   сама `project/1`, тесты `ProjectionCase` зелёные.
4. **Dialyzer** на фикстуре (`out/dialyzer_fixture.out`): в `lib/blind/**` только `unknown_type` отсутствующих
   `Payload.t/0` фикстуры; от сужений и функций-проверок (`NeverFails`, `AlwaysFails`, `load_payload` без ошибки)
   предупреждений нет. Сценарии dialyzer в основном тоже ловит (`call … will not succeed`, `pattern can never match`).

## P1 · Конструктор элемента результата `decide/2`

**Ответ.** Имя `draft/1`, место — кодек `<Aggregate>.Event.Codec` (генерирует `__before_compile__` по `tags:`),
возврат — прежний `{Event.Mod, payload}` / `Event.Mod`. Цикла не добавляет. B1, B3, чужая нагрузка ловятся с понятным
списком ожидаемого. `CompileError` на общий модуль нагрузки выполним, но ломает два законных кодека qc — вместо него
для таких событий генерировать `draft/2`.

### Имя

| Вариант | Против |
|---|---|
| `new/1` | путается с `Event.Opened.new/5` — полным событием с `id`/версией/автором |
| `emit/1` | читается как побочный эффект, а `decide` чистый |
| **`draft/1`** | «черновик события»: без `id`, версии, `by`, `at` — их дописывает `execute`. Выбран |

### Место

| | Кодек `<Aggregate>.Event.Codec` | Семейство `<Aggregate>.Event` |
|---|---|---|
| Чем является сейчас | `use Core.Es.Event.Codec`, знает `tags:`, уже имеет `__before_compile__` | обычный модуль без `use`: вложенные события, `@type t`, `name/1` и `names/0` делегируют кодеку (es_fixture, qc) |
| Что нужно | ничего | новый макрос `use Core.Es.Event.Family, codec:` |
| Компиляция | чисто | **deadlock**: кодек проверяет `event:` через `Helper.Opts.module!` (ждёт семейство), семейство ждёт кодек → `CompileError` в проекции «кодек Blind.Order.Event.Codec … не найден» (`out/p1_family_variant.out`) |
| После ослабления `event:` до `atom!` | — | собирается, но добавляет ребро `event.ex → codec.ex (compile)` (`alias Blind.Order.Event.Codec (compile)`, `out/p1_family_variant_xref.out`) |
| Вызов в `decide` | `Event.Codec.draft(…)` | `Event.draft(…)` |

Выбран кодек: читается на 6 символов длиннее, но не требует нового макроса и не меняет граф компиляции.

### Возврат и совместимость

`draft/1` возвращает тот же кортеж — `Core.Es.Aggregate.events/5`, `Core.Es.Aggregate.Test.given/3` и тип
`Es.Aggregate.result()` не меняются. `es_fixture/account.ex` переведён на `draft/1`: `mix test test/core/es` — 350 passed,
тесты `given/3` с кортежами и `assert {:ok, [Event.Closed]} = decide(…)` проходят. Struct-обёртка
(`%Draft{event:, payload:}`) на компиляции ничего не даёт: тип элемента списка `results` в `apply_decision/4` не
проверяется (`list(term())`), а тесты с кортежами сломались бы.

Сигнатура сгенерированной функции:

```
Blind.Account.Event.Codec:draft/1 [4 clause(s)]
    (Blind.Account.Event.Closed -> Blind.Account.Event.Closed)
    (Blind.Account.Event.Frozen -> Blind.Account.Event.Frozen)
    (%Blind.Account.Event.Opened.Payload{} -> dynamic({Blind.Account.Event.Opened, %…Opened.Payload{}}))
    (%Blind.Account.Event.Renamed.Payload{} -> dynamic({Blind.Account.Event.Renamed, %…Renamed.Payload{}}))
```

### Цикл компиляции

`mix xref graph --format cycles --label compile-connected` у фикстуры — одинаково с кортежами и с `draft/1`
(`out/p1_xref_tuples.out`, `out/p1_xref_draft.out`):

```
Cycle of length 3 (3 compile): lib/blind/account.ex, lib/blind/account/event.ex, lib/blind/account/event/codec.ex
Cycle of length 3 (3 compile): lib/blind/order.ex, …order/event.ex, …order/event/codec.ex
Cycle of length 2 (2 compile): lib/blind/ping.ex, lib/blind/ping/event.ex
```

Цикл существующий, не от `draft`: `account.ex:14: alias Blind.Account.Event.Codec (compile)` — `Macro.expand_literals`
опции `event_codec:` в `use Core.Es.Aggregate`; `event.ex:14: alias Blind.Account.ID (compile)` — `use Core.Es.Event,
aggregate_id:`; кодек грузит события. Вызовы `draft/1` — `(runtime)` (`out/p1_xref_trace_account.out`). Порядок
компиляции — обычный параллельный, без deadlock.

### Что ловится

| Код | `decide` | Итог |
|---|---|---|
| B1 | `Event.Codec.draft(Order.Event.Cancelled)` | ловится |
| B1p | `draft(%Order.Event.Placed.Payload{amount: nil})` | ловится |
| B1n | `draft(Order.Event.Placed.Payload.new(Order.Amount.new!(1)))` | ловится: на проверке сигнатура `Payload.new/1` известна |
| B3 | `draft(Event.Opened)` — голый модуль события с нагрузкой | ловится |
| B1s | `draft("opened")` | ловится |
| B2 | не та нагрузка у своего события | невозможна по построению |
| B2t | обход конструктора: `{Event.Opened, %Event.Renamed.Payload{}}` | молчит — библиотека по-прежнему принимает кортеж |
| B1d | `draft(payload)` с параметром без паттерна | молчит (gradual) |

```
warning: incompatible types given to Blind.Account.Event.Codec.draft/1:
    Blind.Account.Event.Codec.draft(Blind.Order.Event.Placed.Payload.new(Blind.Order.Amount.new!(1)))
given types:
    -dynamic(%Blind.Order.Event.Placed.Payload{amount: %Blind.Order.Amount{}})-
but expected one of:
    #1 Blind.Account.Event.Closed
    #2 Blind.Account.Event.Frozen
    #3 %Blind.Account.Event.Opened.Payload{}
    #4 %Blind.Account.Event.Renamed.Payload{}
└─ lib/scenarios/p1_draft.ex:25:28: Blind.BadDraft.decide/2
```

### Общий модуль нагрузки

`CompileError` выполним (`variants/shared_payload.ex`, `out/p1_shared_payload.out`):

```
** (CompileError) lib/scenarios/zz_shared_payload.ex:34: Es.Event.Codec: нагрузка задаёт событие для draft/1,
а у кодека Blind.Roles.Event.Codec модуль нагрузки общий у нескольких событий:
[{Blind.Roles.RoleID, [Blind.Roles.Event.Granted, Blind.Roles.Event.Revoked]}]
```

Но мешает законным случаям. es_fixture — дублей нет. qc — два кодека:

| Кодек qc | События | Нагрузка |
|---|---|---|
| `Perms.Common.UserRoles.Event.Codec` | `RoleGranted`, `RoleRevoked` | `Role.ID` |
| `Perms.Common.Role.Event.Codec` | `PermAdded`, `PermRemoved` | `Perm.ID` |

Остальные Prim-нагрузки qc (`User.ID`, `Comment`, `Process.Step.Code`, `ClaimAct.ID`…) в пределах кодека уникальны.

Рекомендация: для модулей нагрузки, общих у нескольких событий кодека, генерировать не `CompileError`, а только
`draft/2` — `draft(Event.RoleGranted, %Role.ID{})`, clause на пару событие–нагрузка. Проверено рукописным модулем в форме
сгенерированного (`variants/draft2.ex`, `out/p1_draft2.out`): ловятся и «не та нагрузка у своего события», в том числе
через `Payload.new/1`, и событие без нагрузки с нагрузкой:

```
warning: incompatible types given to Blind.Draft2.draft/2:
    Blind.Draft2.draft(Blind.Account.Event.Opened, Blind.Account.Event.Renamed.Payload.new(name))
given types:
    (Blind.Account.Event.Opened, dynamic(%Blind.Account.Event.Renamed.Payload{name: %Blind.Account.Name{}}))
but expected one of:
    #1 Blind.Account.Event.Opened, %Blind.Account.Event.Opened.Payload{}
    #2 Blind.Account.Event.Renamed, %Blind.Account.Event.Renamed.Payload{}
└─ lib/scenarios/zz_draft2.ex:20:56: Blind.S.Draft2.b2_new/1
```

У `draft/2` при несовпадении пары оба аргумента не подсвечены `-…-`: ошибка совместная, виден только список пар.

### `QC…User.decide/2` в новой форме

Проверено компиляцией копии в фикстуре (`consumer/lib/blind/user.ex`, 0 предупреждений).

```elixir
# было — lib/qc/domain/users/common/user.ex:216-251
def decide(%Cmd.Create{} = command, %__MODULE__{version: nil}) do
  with :ok <- ensure_login(command.type, command.login) do
    {:ok, [{Event.Created, Event.Created.Payload.new(command.type, command.login, :active)}]}
  end
end

def decide(%Cmd.Delete{}, %__MODULE__{}), do: {:ok, [Event.Deleted]}

def decide(%Cmd.Block{}, %__MODULE__{}), do: {:ok, [Event.Blocked]}

def decide(%Cmd.ChangeLogin{login: login}, %__MODULE__{} = user),
  do: {:ok, [{Event.LoginChanged, Event.LoginChanged.Payload.new(user.login, login)}]}

# стало
def decide(%Cmd.Create{} = command, %__MODULE__{version: nil}) do
  with :ok <- ensure_login(command.type, command.login) do
    {:ok, [Event.Codec.draft(Event.Created.Payload.new(command.type, command.login, :active))]}
  end
end

def decide(%Cmd.Delete{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Deleted)]}

def decide(%Cmd.Block{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Blocked)]}

def decide(%Cmd.ChangeLogin{login: login}, %__MODULE__{} = user),
  do: {:ok, [Event.Codec.draft(Event.LoginChanged.Payload.new(user.login, login))]}

# UserRoles с общей нагрузкой Role.ID — draft/2 (было `|> Enum.map(&{event, &1})`)
defp events(role_ids, event, keep?) do
  role_ids
  |> Enum.uniq()
  |> Enum.filter(keep?)
  |> Enum.sort_by(&Role.ID.value/1)
  |> Enum.map(&Event.Codec.draft(event, &1))
end
```

Модуль события теперь назван один раз — в пути модуля нагрузки; парный `{Event.X, Event.X.Payload.new(…)}` уходит.
В `UserRoles` проверка слабая (не проверялось компиляцией): нагрузка — параметр `fn` из `Enum.map`, то есть
`dynamic()`, и пару событие–нагрузка компилятор здесь не сверит.

## P2 · Функции-проверки полноты

**Ответ.** Все срабатывают на строке `use` и без ложных срабатываний. Сверх заказанного ловятся опечатки в поле нагрузки
без паттерна `%Payload{}` (C2a, G3a) и H2 через `Payload.new/1`. Читаемость дают два приёма: имя функции-проверки —
нарушенное утверждение, паттерн события — только `payload:`.

| Код | Ошибка | Где проверка | Итог |
|---|---|---|---|
| C1 | нет clause `evolve` для `Closed` | `use Core.Es.Aggregate.Repo` | ловится |
| C2a | `payload.nmae` при `%Opened{payload: payload}` | то же | ловится |
| C4 | `%{state \| nmae: …}` | то же | ловится |
| G1 | нет clause `project/1` для `Closed` | `__before_compile__` проекции | ловится |
| G3a | `payload.nmae` в `project/1` | то же | ловится |
| H1 | нет `dump_payload`/`load_payload` для `Lost` | `__before_compile__` кодека | ловится, два предупреждения |
| H2 | `load_payload(Sent)` отдаёт литерал `%Account…Renamed.Payload{}` | то же | ловится |
| H2n | то же через `Account.Event.Renamed.Payload.new(name)` | то же | ловится |

Генерируется (на каждое событие; для кодека — на каждое событие с нагрузкой):

```elixir
@doc false
def unquote(:"evolve/2 принимает Blind.Account.Event.Closed")(%Blind.BadEvolveMissing{} = state,
      %Blind.Account.Event.Closed{payload: nil} = event),
    do: Blind.BadEvolveMissing.evolve(state, event)

@doc false
def unquote(:"load_payload/3 отдаёт нагрузку Blind.Parcel.Event.Sent.Payload")(Blind.Parcel.Event.Sent, wire, codec) do
  case load_payload(Blind.Parcel.Event.Sent, wire, codec) do
    {:ok, %Blind.Parcel.Event.Sent.Payload{}} -> :ok
    {:error, _} -> :ok          # только эта clause с generated: true в meta
  end
end
```

Сообщение, итоговая форма (`out/final_compile.out`):

```
warning: incompatible types given to Blind.BadEvolveMissing.evolve/2:
    Blind.BadEvolveMissing.evolve(state, event)
given types:
    dynamic(%Blind.BadEvolveMissing{}), -dynamic(%Blind.Account.Event.Closed{payload: nil})-
but expected one of:
    #1 (%{..., name: term()}, %Blind.Account.Event.Opened{payload: %{..., name: term()}} or
                              %Blind.Account.Event.Renamed{payload: %{..., name: term()}})
    #2 %{..., status: term()}, %Blind.Account.Event.Frozen{}
type warning found at:
 22 │   use Core.Es.Aggregate.Repo,
└─ lib/scenarios/p2_evolve.ex:22: Blind.BadEvolveMissing.Repo."evolve/2 принимает Blind.Account.Event.Closed"/2

warning: the following clause will never match:
    {:ok, %Blind.Parcel.Event.Sent.Payload{}} ->
because it attempts to match on the result of:
    load_payload(Blind.Parcel.Event.Sent, wire, codec)
which has type:
    dynamic({:ok, %Blind.Account.Event.Renamed.Payload{}})
 63 │   use Core.Es.Event.Codec,
└─ lib/scenarios/h_codec.ex:63: Blind.Parcel.Event.Codec."load_payload/3 отдаёт нагрузку Blind.Parcel.Event.Sent.Payload"/3
```

**Как пришли к читаемой форме** (`out/p1p2_v1_compile.out` → `out/p1p2_v2_compile.out`):

| Было (v1) | Проблема | Стало (v2) |
|---|---|---|
| `__es_evolve_covers__/2`, `__es_project_covers__/1` | из места не видно, что нарушено | имя-утверждение `"evolve/2 принимает <Event>"` — печатается в `└─` |
| полный паттерн события (`id`, `aggregate_id`, `at`, `by`, `aggregate_version`) | 20 строк шума в `given types` и `where "event"` | только `payload: %Payload{}` / `payload: nil` |
| проекция и кодек: строка `defmodule` (место `__before_compile__`) | указывает не на опции | `@es_use_line` из `__using__`, `quote line:` — строка `use` |

Комментарий внутри `quote` в сообщение не попадает; `@doc false` скрывает функции из документации, но не из
`__info__(:functions)`.

**Ложных срабатываний нет** (0 предупреждений в `lib/blind/**`):

- событие без нагрузки — `Frozen`, `Closed`, `Pinged`, `Blocked`, `Deleted`;
- `evolve` с `%Payload{}` в паттерне (`Account` `Opened`) и без (`Renamed`, `User`);
- проекция на события двух агрегатов — `Blind.Projection` (`Account` + `Order`);
- кодек без событий с нагрузкой — `Ping`: проверок нагрузки не генерируется, `Ping.Repo` проверяет `evolve`;
- кодек с `upcasts:` — `Account`;
- `load_payload`, который никогда не возвращает ошибку (`CodecNew` `Lost`): clause `{:error, _}` с `generated: true` в
  meta молчит, а clause `{:ok, %Payload{}}` той же `case` предупреждает — подавление работает на уровне clause.

**Находки.**

1. H2 ловится и при `Payload.new/1` того же проекта: на проходе проверки результат локальной `load_payload/3`
   перевычисляется с известными сигнатурами удалённых вызовов (`{:ok, %Renamed.Payload{name: %Name{}}}`).
   Исследование 02 ожидало `term()` — это верно только для вывода сигнатуры в ExCk.
2. Проверка `evolve` живёт в `Account.Repo` и ловит только агрегат, у которого есть репозиторий. `BrokenAccount`
   es_fixture без `Repo` не проверяется.
3. Имена функций-проверок — атомы с пробелами (`String.to_atom` на компиляции из модулей, не из внешних данных).
   Альтернатива без них — `__es_…_covers__`, читаемость хуже (v1).

## P3 · Храповик предупреждений фикстуры

**Ответ.** Диагностики — через Mix API, не разбором текста. Ожидание — маркер `# expect: <начало заголовка>` строкой над
ошибочной строкой. Скрипт `ratchet/check_warnings.exs` падает и на пропавшем, и на лишнем предупреждении и переживает
сдвиг строк. Фикстуре — отдельный каталог вне `lib|test|config` со своими `_build`/`deps` и общим `mix.lock`.

### Сбор предупреждений

```elixir
Mix.Task.rerun("deps.loadpaths", [])                    # пересобрать устаревший core (см. находку 1)
{_status, diagnostics} = Mix.Task.run("compile", ["--force", "--return-errors"])
# %Mix.Task.Compiler.Diagnostic{severity: :warning, file: "/…/lib/scenarios/p2_evolve.ex", position: 22,
#   message: "incompatible types given to …", stacktrace: [{Blind.BadEvolveMissing.Repo, :"evolve/2 …", 2, …}]}
```

Разбор текста хуже: формат зависит от режима. Когда в том же прогоне собираются зависимости, место печатается как
`└─ (blind 0.1.0) lib/…`, без них — `└─ lib/…`.

Запуск: `mix run --no-start --no-compile ../ratchet/check_warnings.exs` из `consumer/`; прогон при собранном core —
0,8 с на 30 файлов, первая сборка зависимостей — около 40 с.

### Формат эталона

| | Маркер в исходнике | Файл `file:line: title [mfa]` | Файл `file: title [mfa]` |
|---|---|---|---|
| Сдвиг строк на 7 в `p0.ex` | 0 расхождений | 16 из 30 строк разошлись | 0 |
| Различает два одинаковых предупреждения в одной функции | да (строка) | да | нет, только по числу (`BadDraft.decide/2` × 4) |
| Где видно ожидание | рядом с ошибкой | отдельный файл | отдельный файл |
| `mix format` | переносит хвостовой `# expect:` строкой выше — та же семантика | — | — |

Выбран маркер. Правила: маркер строкой относится к следующей строке кода, маркеры копятся (три над одним `use`
кодека); хвостовой — к своей строке; совпадение — файл, строка и подстрока первой строки сообщения; маркер съедает одно
предупреждение. `--dump` печатает эталон строками для ревью.

```elixir
def a1_foreign_cmd(%Account{} = state, %Order.Cmd.Place{} = cmd),
  # expect: incompatible types given to Blind.Account.execute/2
  do: Account.execute(state, cmd)

# expect: incompatible types given to Blind.BadEvolveMissing.evolve/2
use Core.Es.Aggregate.Repo,
```

### Самопроверка (`ratchet/selftest.sh`, `out/p3_selftest.out`)

```
== 1. исходное состояние
ratchet: ok — 30 ожидаемых предупреждений, лишних нет                              exit=0
== 2. пропавшее предупреждение (C1 починен, маркер остался)
ratchet: FAIL — маркеров 30, пропало 1, лишних 0
  пропало: lib/scenarios/p2_evolve.ex:23: incompatible types given to Blind.BadEvolveMissing.evolve/2   exit=1
== 3. лишнее предупреждение (опечатка в lib/blind/usecase.ex)
ratchet: FAIL — маркеров 30, пропало 0, лишних 1
  лишнее:  lib/blind/usecase.ex:60: unknown key .nmae in expression: [Blind.Usecase.typo/1]            exit=1
== 4. сдвиг строк в p0.ex на 7
ratchet: ok — 30 ожидаемых предупреждений, лишних нет                              exit=0
== 5. эталон file:line при сдвиге на 7: строк 30, разошлось 16
== 5b. эталон file: title [mfa] без строки: разошлось 0
```

### Отдельный `_build` и соседство с core-ex

- Фикстура — самостоятельный Mix-проект: path-зависимость собирается в `consumer/_build/dev/lib/core`, `_build` core-ex не
  трогается (mtime `_build/dev/lib/core/ebin/*.beam` core-ex после прогонов не менялся).
- Каталог — вне `config|lib|test`. Внутри `test/` фикстура попала бы в `mix format` (`test/**/*.{ex,exs}` вместе с её
  `deps/**`), в `layout_lint` (`@form ["test/**/*.{ex,exs}"]`, без исключения `deps`) и в credo (`test/`, сценарии с
  намеренными ошибками).
- `.gitignore` core-ex якорит `/_build/` и `/deps/` к корню — у фикстуры свой `.gitignore`.
- `lockfile: "../../../../mix.lock"` — версии как у core-ex. `HEX_OFFLINE=1 mix deps.get` lock core-ex не меняет.
- Фикстуру стоит собирать с явным `MIX_ENV=dev`, чтобы `MIX_ENV=test` из окружения `make` не менял каталог сборки.

Цель `make`, предлагаемая форма:

```make
consumer-check:
	cd test_consumer && MIX_ENV=dev HEX_OFFLINE=1 mix deps.get && \
	  MIX_ENV=dev mix run --no-start --no-compile ../scripts/consumer_warnings.exs
```

**Находки.**

1. `mix run --no-compile` не пересобирает изменённую path-зависимость: `deps.loadpaths` уже отработал с `--no-compile`,
   и `Mix.Task.run("compile")` его не повторяет. Храповик сверял бы предупреждения со старым core. Нужен
   `Mix.Task.rerun("deps.loadpaths", [])` в скрипте или `mix deps.loadpaths` перед ним — проверено по mtime beam.
2. `lockfile:` на чужой lock — признак umbrella-ребёнка для dialyxir: `mix dialyzer` в фикстуре печатает
   «In an Umbrella child, not checking PLT…» и пропускает сборку PLT. Для храповика неважно, dialyzer фикстуры
   (`out/dialyzer_fixture.out`) снят без `lockfile:`.

## Не проверено

- **F2** — чужая команда в `Agg.Process.execute`. Решения 1–2 его не закрывают, способ не прототипировался.
- **Семейство как место `draft/1`** — только имитация макроса в фикстуре (`variants/family_draft.ex`), не библиотечный
  `use`.
- **`draft/2` для общих нагрузок** — рукописный модуль, генерация в кодеке не написана.
- **qc** не собирался против правок; `QC…User.decide` проверен копией в фикстуре.
- **Git-зависимость** — только `path:`.
- **Проверка `evolve`** у агрегата без `<Aggregate>.Repo` не срабатывает, альтернативное место (`EventCompatCase`,
  процесс) не пробовалось.
- **Цель `make`** не добавлялась в `Makefile`, `.pre-commit-config.yaml` не трогался; скрипт лежит в прототипе.
- **Umbrella** не проверялся.
