# Система типов Elixir 1.20: что проверяется при компиляции и что её ослепляет

Исследование на 2026-09-17. Версии: Elixir 1.20.3 (OTP 29).

## Вопрос

Что проверяет gradual set-theoretic система типов Elixir 1.20 при компиляции. Какие конструкции ослепляют её:
тип выводится как `dynamic()`/`term()`, проверка не выполняется или предупреждение подавляется. Что из этого
закрыто только в runtime (`FunctionClauseError`), а что можно превратить в предупреждение компиляции. Контекст —
типобезопасность `Core.Es`; код библиотеки не аудировался.

Методика и обозначения:

- Исходники — тег `v1.20.3`. Локальная установка совпадает с тегом побайтно: `module/types.ex`, `module/types/*.ex`,
  `parallel_checker.ex`, `behaviour.ex`, `CHANGELOG.md`.
- `[N:a-b]` — строки `a-b` источника `N` на теге; `[N]` без строк — источник целиком (для экспериментов — файл).
- Эксперименты собраны `elixirc` 1.20.3: все модули одного вызова — «один проект». Межмодульные случаи — в
  Mix-проекте `proj/app` с path-зависимостью `proj/dep_lib`.
- Выведенные сигнатуры прочитаны из чанка `ExCk` скриптом [26].
- Вывод компилятора ниже сокращён до заголовка, типов и места; полный — в `*.out` рядом с файлом.
- «Молчит» — компилятор не выдал предупреждения. Для ключевых молчащих случаев падение в runtime подтверждено [46].

## Как устроена проверка

**Два прохода.**

1. *Вывод* идёт при компиляции модуля, до записи `.beam`. `Module.Types.infer/7` в режиме `:infer` строит
   сигнатуру каждой `def` [20:197-206][7:37-130] и пишет её в чанк `ExCk` [21:652-674]. Режим `:infer` описан так:
   «Same as :dynamic but skips remote calls» [7:21-25]. Удалённый вызов получает сигнатуру, только если модуль
   принадлежит приложению из `infer_signatures`: такие модули заранее помечены в кеше как `:uncached`
   [14:546-567][8:1544-1554]. Модули текущей компиляции регистрируются в кеше только на старте проверки
   [14:598-601, 665-685]. До этого `fetch_export(..., false)` отдаёт `:badmodule`, сигнатура — `:none`, результат —
   `dynamic()` [14:239-262][8:1454-1456].
2. *Проверка* идёт после компиляции всех модулей и после `after_compile`: `verify_modules` →
   `ParallelChecker.verify` [18:457-477]. `Module.Types.warnings/6` в режиме `:dynamic` проходит все функции
   [14:266-297][7:219-243]. Удалённый вызов здесь берёт сигнатуру любого модуля — из кеша компиляции или из `ExCk`
   загруженного `.beam` через `fetch_export(..., true)` [8:1556-1583][14:426-461]. В этом же проходе — проверки
   `@behaviour`/`@impl` [14:270-278].

Режим `:static` объявлен [7:17-19, 31], но в компиляторе не используется: поиск `:static` по `lib/` находит только
`@modes`. Режим `:strict` «not implemented» [7:13]. Значит, каждая проверка идёт по gradual-правилам.

**`infer_signatures`.**

- Mix ставит `:elixir`, `extra_applications`, `included_applications` и все зависимости с `app: true` [23:139-154, 200-222].
- Вне Mix значение — `[:elixir]` [19:1769-1775].
- `mix test` компилирует тестовые файлы с `infer_signatures: false` [25:28-31]: сигнатуры тестовых модулей не
  выводятся, проверка идёт [45].

**Семантика `dynamic()`.**

- Аргументы каждой функции начинаются как `dynamic()` [7:150-169][1:201-214].
- Аргумент без статической части — ошибка, только если его тип не пересекается с ожидаемым (`compatible?`,
  `disjoint?`) [13:935-978].
- Результат вызова в режиме `:dynamic` оборачивается в `dynamic(...)` [8:1766-1775, 1852-1863]. Результаты
  `case`/`cond`/`with`/`try` — тоже [9:970-971].
- Отсюда «verified bugs»: предупреждение — только если провал гарантирован [5:57-72][1:236].
- `dynamic` всегда на корне: `{:ok, dynamic()}` переписывается в `dynamic({:ok, term()})` [1:218].

```elixir
def dynamic_compatible(c) do
  v = if c, do: 1, else: "a"
  v + 1
end

def dynamic_disjoint(c) do
  v = if c, do: 1, else: "a"
  Map.fetch!(v, :k)
end
```

```
warning: incompatible types given to Map.fetch!/2:
    given types: -dynamic(binary() or integer())-, :k
└─ e01_basics.ex:39:9: E01.dynamic_disjoint/1
```

`dynamic_compatible/1` молчит [27].

**Сигнатура из clauses.**

- Выведенная сигнатура — список пар `(аргументы -> результат)` по clauses. Clauses с одинаковым результатом,
  различающиеся одним аргументом, сливаются [7:520-570][42].
- Применение ошибочно, только если аргументы не пересекаются ни с одной clause.
- Результат — объединение результатов подходящих clauses. Если подходящих больше `@max_clauses 16`, результат —
  `dynamic()` [8:16, 1852-1894].

**Подавление.**

- Узел AST с `generated: true` предупреждений не выдаёт [12:535-570].
- После первой *ошибки* (`failed: true`) последующие ошибки в том же пути выполнения не собираются. Тип ошибочного
  выражения — `dynamic()` [12:553-574].
- `case` по литералу или сгенерированному выражению помечает свои clauses как `generated`. Проверено только чтением
  кода, экспериментом — нет [9:434-450].

## Что проверяется

| Проверка | Пример из эксперимента | Где |
|---|---|---|
| Тип аргумента локального, удалённого и stdlib-вызова | `Integer.to_string(x)` при `when is_binary(x)`; `priv("s")` при `defp priv(x) when is_integer(x)`; `E02.Strict.decide("rename", …)` | [27][28] |
| Clause `case`/`with`, которая не совпадёт с результатом вызова | `{:error, _} ->` по `dynamic({:ok, non_empty_list(binary())})` | [28][35], [2:75-88] |
| Избыточная clause: `def`, `case`, `_ ->` после исчерпания | повторный `def redundant(%Evt{})`; `_ ->` после `{:ok, events}` | [27][35][11:183-219] |
| Clause `defp`, до которой не доходит ни один вызов | `this clause of defp handle/1 is never used` | [39][7:245-290] |
| Guard, который никогда не истинен | `when is_integer(x) and is_binary(x)` | [27] |
| Несуществующее поле struct / ключ map | `e.amout` при `%Evt{} = e`; `%{a: 1}.b`; `%{s \| balanse: 1}` | [27][34][9:166-207] |
| `Map.fetch!`/`Map.get`/`Map.update!` по отсутствующему ключу | `Map.update!(e, :amout, & &1)` | [33][8:1134-1450], [2:114-137] |
| Индекс кортежа | `elem(t, 2)` при `{_, _} = t` | [27] |
| Элементы списка | `byte_size(hd([1]))` | [33] |
| Сегменты бинарника | `"a" <> x` при `is_integer(x)` | [27] |
| Сравнение непересекающихся типов и struct | `e < ~D[2020-01-01]` | [27] |
| Применение `fn` и захвата, арность | `fun.("x")`; `fun = &Account.evolve/2; fun.(%Account{}, "bad event")` | [36][9:498-515, 669-677], [3:75-111] |
| `is_function(fun, n)` в guard вызываемой функции | `Transact.run(fn x -> x end)`, `Transact.run(:not_a_fun)` | [36] |
| Вызов функции на не-атоме | `m.get(1)` при `%{} = m` → `expected a module (an atom)` | [29][10:712-724] |
| Диспетчеризация протокола (при консолидации) | `App.Proto.dump("x")`, `"#{%App.Local{}}"`, `for x <- %App.Local{}` | [38][16:628-724], [3:11-73] |
| Первый аргумент функции в `defimpl` | `local.missing_field` в `defimpl App.Proto, for: App.Local` | [38][7:136-169] |
| Поле исключения в `rescue` | `e in ArgumentError -> e.mesage` | [35][9:517-567] |
| Обновление struct без доказанного типа | `%__MODULE__{s \| balance: 1}` при `s` без паттерна | [34][9:209-258], [1:260-274] |
| Вызовы в тестовых файлах | `App.Local.to_int("x")` внутри `assert_raise` | [45] |

## Откуда берутся сигнатуры

- **Паттерны, guards и тело всех clauses** [2:17-73]. Пример:
  `def evolve(%__MODULE__{} = s, %Deposited{amount: a}), do: %{s | balance: s.balance + a}` выводится в
  `(%E09.Account{balance: float() or integer()}, %E09.Deposited{amount: float() or integer()} -> dynamic(%E09.Account{balance: float() or integer()}))`
  [34].
- **Локальные вызовы** проходятся при выводе: `def get_or_default(id), do: get(id)` получает домен `get/1`, и
  `E04.Plain.get_or_default("x")` ловится [30][7:292-317].
- **Тот же проект.** Место вызова проверяется по сигнатуре: `App.Caller.local_direct` →
  `incompatible types given to App.Local.to_int/1`. В вывод сигнатуры вызывающей функции удалённый вызов не
  попадает [38][8:1544-1554][1:234]:

  ```
  App.Facade:to_int/1            (term() -> dynamic())        # def to_int(x), do: App.Local.to_int(x)
  App.Facade:delegated_to_int/1  (term() -> dynamic())        # defdelegate ..., to: App.Local, as: :to_int
  App.Facade:status/0            ( -> dynamic())              # def status, do: App.Local.status()
  ```

  `App.Facade.to_int("x")`, `App.Facade.delegated_to_int("x")` и `case App.Facade.status()` с `:error ->` молчат.
  То же у обёртки из `quote`: `def load(raw), do: unquote(codec).load!(raw)` → `(term() -> dynamic())` [31].
- **Зависимость.** Сигнатуры зависимости участвуют и в выводе [2:73, 304][38]:

  ```
  App.Facade:dep_to_int/1  (integer() -> integer())   # def dep_to_int(x), do: DepLib.to_int(x)
  App.Facade:dep_status/0  ( -> dynamic(:ok))
  DepLib.Facade:to_int/1   (term() -> dynamic())      # внутри dep_lib: тот же проект
  ```

  `App.Facade.dep_to_int("x")` и `case App.Facade.dep_status()` с `:error ->` ловятся. `DepLib.Facade.to_int("x")`
  молчит.
- **Erlang/OTP.** У модуля без `ExCk` в кеше только экспорты [14:426-461]. Тип есть лишь у функций из встроенного
  списка [8:140-341]: `:erlang.atom_to_binary("not an atom")` ловится, `:lists.reverse(:not_a_list)` и
  `:crypto.strong_rand_bytes("not an integer")` молчат [44].
- **`@spec` не используется.** В `module/types.ex` и `module/types/*.ex` нет обращений к spec. Пользовательские
  сигнатуры — будущая веха, Erlang typespecs «will be phased out» [1:16, 276-282]. Эксперимент [32]:

  ```elixir
  @spec bump(binary()) :: binary()
  def bump(n) when is_integer(n), do: n + 1
  # в другом модуле:
  case E05.Account.bump(1) do
    b when is_binary(b) -> b
  end
  ```

  ```
  warning: the following clause will never match:
      b when is_binary(b) ->
  because it attempts to match on the result of: E05.Account.bump(1)
  which has type: integer()
  ```

  Противоречие `@spec` и тела не сообщается. `@spec deposit(integer()) :: binary()` при `def deposit(amount), do: amount`
  даёт `(term() -> dynamic())`, и `deposit("not an integer")` молчит.
- **`@callback`/`@behaviour`/`@impl`** проверяют только наличие, вид и разметку колбэков [15:17-32][14:270-278].
  Типы `@callback` не читаются: реализация `@spec evolve(integer(), atom()) :: atom()` при
  `@callback evolve(struct(), struct()) :: struct()` проходит без предупреждений [32]. Исключение — `defimpl`:
  первый аргумент колбэка протокола получает тип реализации [7:136-169][10:259-299].
- **Протоколы.** Консолидация пишет в `ExCk` протокола сильную сигнатуру: домен первого аргумента — объединение
  типов реализаций, результат — `dynamic()` [16:668-724]. Mix консолидирует в `after_compile` до проверки
  [24:1157-1162][18:457-477]; в umbrella консолидация выключена [24:175-183].
- **Поля struct.** Тип struct из `__info__(:struct)` — все поля `dynamic()` [10:525-533]. В паттерне `%Mod{}`
  неуказанные поля — `term()`, указанные — «dynamic until we have typed structs» [11:700-755]. У литерала
  struct тип значений известен, включая значения по умолчанию: при `defstruct balance: 0`
  `byte_size(%__MODULE__{}.balance)` ловится с `given types: -integer()-` [10:460-491][34].
  Typed structs — следующая веха [1:276-280][6:189-195].

## Что ослепляет: проверка гипотез

### 1. Catch-all clause и clause с `raise`

**Для аргументов — подтверждено. Для результата `raise`-clause — опровергнуто.** Clause `(term(), term() -> …)`
пересекается с любым аргументом, поэтому применение не находит ошибки [8:1852-1894].

```elixir
defmodule E02.Strict do
  defstruct [:name]
  def decide(%E02.Rename{name: n}, %__MODULE__{}) when is_binary(n), do: {:ok, [n]}
end

defmodule E02.CatchAllRaise do
  defstruct [:name]
  def decide(%E02.Rename{name: n}, %__MODULE__{}) when is_binary(n), do: {:ok, [n]}
  def decide(cmd, _state), do: raise(ArgumentError, "unknown #{inspect(cmd)}")
end
# E02.CatchAllError — то же, второй clause: def decide(_cmd, _state), do: {:error, :unknown_command}
```

Сигнатуры [28]:

```
E02.Strict:decide/2         (%E02.Rename{name: binary()}, %E02.Strict{} -> dynamic({:ok, non_empty_list(binary())}))
E02.CatchAllRaise:decide/2  (%E02.Rename{name: binary()}, %E02.CatchAllRaise{} -> dynamic({:ok, non_empty_list(binary())}))
                            (term(), term() -> none())
E02.CatchAllError:decide/2  (%E02.Rename{name: binary()}, %E02.CatchAllError{} -> dynamic({:ok, non_empty_list(binary())}))
                            (term(), term() -> {:error, :unknown_command})
```

- `E02.Strict.decide("rename", %E02.Strict{})` → `warning: incompatible types given to E02.Strict.decide/2`.
- `CatchAllRaise.decide("rename", …)` и `CatchAllError.decide("rename", …)` молчат.
- `case CatchAllRaise.decide(%E02.Rename{name: "a"}, …)` с `{:error, _} ->` → `the following clause will never match`:
  результат `raise`-clause — `none()`, он не расширяет тип.
- Catch-all из `@before_compile` (`def evolve(state, _event), do: state`) слепит так же:
  `E04.Agg.evolve(%E04.Agg{}, "not an event")` молчит [30].

### 2. Динамический вызов

**Подтверждено для модуля из параметра, конфигурации, `apply/3`, `Module.concat`. Опровергнуто для атрибута модуля и
литерала.** Для `expr.fun(...)` компилятор берёт тип `expr`. Конечное множество атомов даёт проверку по каждому
модулю. Бесконечное (`dynamic()`, `atom()`) даёт пустой список модулей: вызов идёт без модуля, сигнатура `:none`,
результат `dynamic()` [9:723-727][10:712-724][8:89-93, 354-367, 954-962][13:1223-1238].

| Форма [29] | Результат | Причина |
|---|---|---|
| `@repo.get("id")`, `case @repo.get(1)` с `:error ->` | ловится | атрибут раскрывается в литерал: вызов на известном модуле |
| `repo = E03.Repo; repo.get("id")` | ловится | тип переменной — `E03.Repo` |
| `codec = if flag, do: E03.Codec, else: E03.Repo; codec.load!("raw")` | ловится для каждого модуля | конечное множество атомов |
| `def f(codec) when codec in [E03.Codec], do: codec.load!("raw")` | ловится | guard сужает до атома |
| `cfg = %{codec: @codec}; cfg.codec.load!("raw")` | ловится | литеральная map |
| `def f(codec), do: codec.load!("raw")`; `case repo.get(1)` по параметру | молчит | `dynamic()` |
| `def f(cfg), do: cfg.codec.load!("raw")` | молчит | `dynamic()` |
| `Application.fetch_env!(:e03, :repo)` → `repo.get("id")` | молчит | результат `dynamic()` |
| `Module.concat([E03, Repo]).get("id")` | молчит | результат не конечный атом |
| `apply(E03.Repo, :get, ["id"])` | молчит, runtime `FunctionClauseError` [46] | `apply/3` инлайнится в `:erlang.apply/3` [22:101-102] с сигнатурой `(atom(), atom(), list(term())) -> dynamic()` [8:161-162] |

### 3. Код из макроса: `use`, `__using__`, `@before_compile`, `@impl true` в `quote`

**Как класс — опровергнуто.** Функции из `quote` — обычные `def` модуля-потребителя, они выводятся и проверяются [30].

```elixir
defmacro __using__(opts) do
  id = Keyword.fetch!(opts, :id)

  quote do
    @behaviour E04.RepoBehaviour

    @impl true
    def get(%unquote(id){} = id), do: {:ok, id}

    def buggy, do: Integer.to_string("not an int")

    def get_or_default(id), do: get(id)

    defoverridable get: 1
  end
end
```

- `E04.Plain.get("x")` и `E04.Plain.get_or_default("x")` ловятся.
- Переопределение `def get(%E04.Id{value: v} = id) when is_integer(v), do: super(id)` ловит
  `E04.Overridden.get(%E04.Id{value: "x"})`.
- Ошибка внутри `quote` сообщается на строке `use`:

  ```
  warning: incompatible types given to Integer.to_string/1:
  │
  38 │   use E04.Using, id: E04.Id
  └─ e04_macros.ex:38: E04.Plain.buggy/0
  ```

Слепят три частных случая:

- **`generated: true`.** Предупреждения внутри размеченного кода подавлены [12:535-570]: `E04.Generated.buggy` молчит.
  Внешний вызов `E04.Generated.get("x")` ловится — разметка стоит у вызываемого кода, не у места вызова [30].
- **Catch-all через `@before_compile`** — см. п. 1.
- **Обёртка на модуль того же проекта** [31]:

  ```elixir
  quote do
    def load(raw), do: unquote(codec).load!(raw)
    def load_literal_bug, do: unquote(codec).load!("not a map")
  end
  ```

  `E04b.Repo.load/1` → `(term() -> dynamic())`, `E04b.Repo.load("not a map")` молчит. Литеральный вызов
  `load_literal_bug` ловится с местом `e04b_unquote_module.ex:17: E04b.Repo.load_literal_bug/0`.

### 4. Behaviour-колбэк через модуль-переменную

**Подтверждено** [32].

```elixir
def fold(mod, state, events) when is_atom(mod) and is_list(events),
  do: Enum.reduce(events, state, &mod.evolve(&2, &1))

def fold_one(mod, state, event), do: mod.evolve(state, event)
```

- `fold_one(E05.Account, %E05.Account{}, "bad event")` и `fold(E05.Account, %E05.Account{}, ["bad event"])` молчат;
  сигнатура `fold_one/3` — `(atom(), term(), term() -> dynamic())`.
- Прямой `E05.Account.evolve(%E05.Account{}, "bad event")` ловится.
- `@callback` к проверке ничего не добавляет (см. «Откуда берутся сигнатуры»).

### 5. Протоколы

**При консолидации — опровергнуто, без неё — подтверждено.** В Mix-проекте с консолидацией ловятся [38]: прямой
вызов функции своего протокола и протокола зависимости, интерполяция и генератор `for` по типу без реализации.

```
warning: incompatible types given to App.Proto.dump/1:
    App.Proto.dump("x")
    given types: -binary()-
    but expected a type that implements the App.Proto protocol.
    hint: the App.Proto protocol is implemented for the following types:
        dynamic(%App.Local{}) or integer()
└─ lib/app/caller.ex:38:35: App.Caller.app_protocol/0
```

- `mix compile --force --no-protocol-consolidation` убирает все четыре протокольных предупреждения; остальные семь
  остаются, включая поле в `defimpl` [41].
- В umbrella консолидация выключена [24:175-183]; экспериментом не проверялось.
- Косвенный вызов протокола через функцию с широким доменом молчит: `Enum.map(123, & &1)`, домен `Enum.map/2` —
  `not %Range{}` [33]; в runtime — `Protocol.UndefinedError` [46].
- Результат функции протокола — `dynamic()` [16:712-717].

### 6. Данные из внешнего мира

**Подтверждено; сужение на границе работает.**

- `JSON.decode!/1` → `(binary() -> dynamic())`. `JSON.decode!(raw).amount` молчит, в runtime — `KeyError` [33][46].
- `use Ecto.Repo` генерирует `get!/2` → `(term(), term() -> dynamic())`: `Repo.get!(Row, id).amout` молчит [40].
- `field :amount, :integer` в тип не попадает: `byte_size(r.amount)` при `%Row{} = r` молчит [40].
- Сужение на границе ловит опечатку: `%Row{} = r` в голове и
  `%Row{} = row = Repo.get!(Row, id); row.amout` → `unknown key .amout` [40]. Этот приём документация советует для
  struct update [1:269-274].
- Map со строковыми ключами из паттерна типизируется:
  `def f(%{"amount" => amount}) when is_integer(amount), do: byte_size(amount)` ловится [33].

### 7. `Map`, `Access`, `Keyword`, `Enum`

**Частично подтверждено.** У функций `Map` отдельные правила вывода типа по ключу [8:1134-1450][2:114-137]. Остальное
идёт по выведенной сигнатуре stdlib [33]:

```
Access:get/2    (%{..., __struct__: atom()} or nil or non_struct_map(), term() -> dynamic())
                (empty_list() or non_empty_list(term(), term()), atom() -> dynamic())
Keyword:get/2   (empty_list() or non_empty_list(term(), term()), atom() -> dynamic())
Keyword:fetch!/2 (empty_list() or non_empty_list(term(), term()), atom() -> dynamic())
Enum:map/2      (not %Range{}, term() -> dynamic())
Enum:at/2       (term(), integer() -> dynamic())
Enum:reduce/3   (term(), term(), term() -> dynamic())
```

| Вызов [33] | Результат |
|---|---|
| `byte_size(Map.get(%{amount: 1}, :amount))` | ловится, тип `nil or integer()` |
| `byte_size(Map.get(%{"amount" => 10}, "amount"))` | ловится (domain keys, [2:90-112]) |
| `byte_size(%{amount: 1}.amount)` | ловится |
| `Map.get(e, :amout)`, `Map.update!(e, :amout, & &1)` при `%Evt{} = e` | ловится |
| `Map.put(e, :amout, 1)` при `%Evt{} = e` | молчит: ключ добавляется, результат уже не struct |
| `byte_size(%{amount: 1}[:amount])`, `byte_size(%{"amount" => 10}["amount"])` | молчит: `Access.get/2` → `dynamic()` |
| `e[:amount]` при `%Evt{} = e` | молчит; runtime `UndefinedFunctionError` [46]; домен `Access.get/2` включает struct |
| `byte_size(Keyword.get([timeout: 1], :timeout))`, то же с `Keyword.fetch!` | молчит |
| `Enum.map([1, 2], fn x -> byte_size(x) end)` | молчит: параметры `fn` — `dynamic()` [9:498-515] |
| `byte_size(Enum.at([1], 0))` | молчит |
| `for x <- [1, 2], do: byte_size(x)` | молчит: элемент генератора — `dynamic()`, `TODO: Extract the type from enumerable protocol` [9:820-833] |

Результат stdlib-функции бывает неточным. `String.upcase/1` → `(binary() -> dynamic() or binary())`, поэтому
`String.upcase(x) + 1` молчит, а `Integer.to_string(x) + 1` ловится [44].

### 8. `%Mod{}` против `is_struct/2` и `%{__struct__: mod}`

**Подтверждено.** `is_struct/2` в guard раскрывается в `is_map/1` и `:erlang.map_get(:__struct__, x) == name`
[17:2683-2689]. Паттерны `%{__struct__: Mod}` и `%mod{}` с `when mod == Mod` дают открытую map
[11:757-787][34].

```elixir
def pattern(%Deposited{} = e), do: e.amout
def is_struct_guard(e) when is_struct(e, Deposited), do: e.amout
def struct_key_pattern(%{__struct__: Deposited} = e), do: e.amout
def var_struct_pattern(%mod{} = e) when mod == Deposited, do: e.amout
```

- `pattern/1` → `warning: unknown key .amout in expression`.
- Остальные три молчат. Обращение `e.amout` сужает их домен до `%{..., __struct__: E09.Deposited, amout: term()}` [34].
- Ошибка всплывает у вызывающего, только если тот передаёт известный struct:
  `Account.is_struct_guard(%Deposited{amount: 1})` → `incompatible types given to E09.Account.is_struct_guard/1 …
  expected one of: %{..., __struct__: E09.Deposited, amout: term()}` [34].
- `defguard is_evt(x) when is_struct(x, E24.Evt)` ведёт себя так же [44].
- Документация `is_struct/2`: «does not check that `name` exists and is a valid struct. If you want such
  validations, you must pattern match on the struct instead» [17:2645-2651].

### 9. `with … else`, `case` с `_ ->`, `try/rescue`

**Опровергнуто** [35][9:430-496, 517-567, 645-667, 902-918].

- `_ ->` после clauses, покрывших результат `Decider.decide(1)`: `the following clause cannot match because the
  previous clauses already matched all possible values`.
- `with {:ok, events} <- Decider.decide(1) … else {:error, reason} ->` и `else _ ->`:
  `the following clause will never match`.
- `with {:error, reason} <- Decider.decide(1)`: `the following pattern will never match`.
- Результат `try` — объединение ветвей: `x = try do Integer.parse(s) rescue _ -> nil end; byte_size(x)` →
  `given types: -dynamic(:error or nil or {integer(), binary()})-`.
- `rescue e in ArgumentError -> e.mesage` → `unknown key .mesage`.

Слепые места здесь другие: частично неверный union и неисчерпывающий `case` не сообщаются [43].

```elixir
def evolve(%__MODULE__{} = s, %E23.Deposited{amount: a}), do: %{s | balance: s.balance + a}

def partial_union(flag) do
  event = if flag, do: %Deposited{amount: 1}, else: %Withdrawn{amount: 1}
  Account.evolve(%Account{}, event)
end

def non_exhaustive_case(flag) do
  event = if flag, do: %Deposited{amount: 1}, else: %Withdrawn{amount: 1}
  case event do
    %Deposited{} -> :deposited
  end
end
```

- Обе функции молчат; `partial_union(false)` в runtime — `FunctionClauseError` [46].
- Если в обеих ветвях `%Withdrawn{}` — `incompatible types given to E23.Account.evolve/2`.
- Причина: `if`/`case` в режиме `:dynamic` дают `dynamic(...)` [9:970-971], а gradual-аргументу достаточно
  пересечения [13:964-978].
- Проверки исчерпываемости в 1.20.3 нет [43]; в посте rc.0 она названа будущей возможностью [6:160].

### 10. Анонимные функции и колбэки

**Частично подтверждено** [36].

- Ловится `fn` или захват, применённый в той же функции:

  ```
  warning: incompatible types given on function call:
      fun.(%E11.Account{...}, "bad event")
      given types: %E11.Account{balance: integer()}, -binary()-
  └─ e11_funs.ex:25:8: E11.capture_wrong_arg/0
  ```

  Неверная арность: `expected a 1-arity function on function call`.
- `is_function(fun, 0)` в голове вызываемой функции ловит `Transact.run(fn x -> x end)` и `Transact.run(:not_a_fun)`.
- Молчит: `Enum.reduce(events, %Account{}, &Account.evolve/2)` — аргументы переставлены, runtime
  `FunctionClauseError` [46].
- Молчит: `Enum.reduce(["bad"], %Account{}, &Account.evolve(&2, &1))`.
- Молчит: `Transact.call_with_string(fn %Deposited{} = e -> e end)` при `def call_with_string(fun), do: fun.("x")`.
- Причины:
  - параметры `fn` — `dynamic()`; аргументы `fun.(...)` типизируются без ожидаемого типа («TODO: Perform inference
    based on the strong domain of a function») [9:498-515, 669-677];
  - у параметра-функции выводится только арность: `call_with_string/1` → `((none() -> term()) -> dynamic())`,
    `Transact.run/1` → `((-> term()) -> dynamic())`; тип, с которым функцию применят, в домен не попадает [36];
  - `Enum.reduce/3` — `(term(), term(), term() -> dynamic())` [33].
- Явная рекурсия не помогает [37]: у `fold_rec(state, [event | rest])` второй аргумент выводится как
  `non_empty_list(term(), term())`, то есть элемент — `term()`, и `fold_rec(%Account{}, ["bad"])` молчит.

### 11. Зависимости и порядок компиляции

**Для проверки — опровергнуто, для вывода — подтверждено.**

- Проверка идёт после компиляции всех модулей [18:457-477]. Поэтому модуль того же проекта, скомпилированный
  параллельно или позже, виден месту вызова: `lib/app/caller.ex` ловит вызовы в `lib/app/local.ex` [38].
- Вывод сигнатуры не видит модули того же проекта при любом порядке компиляции [8:1544-1554][38]. Stdlib и
  зависимости видит [23:200-222][38].
- Инкрементальная сборка перепроверяет модули, которые ссылаются на изменённые, без их перекомпиляции
  [24:1230-1267]. После замены guard `App.Local.to_int/1` на `is_binary` `mix compile` печатает
  `Compiling 1 file (.ex)`. Предупреждение `local_direct` пропадает, появляется новое в
  `lib/app/facade.ex:3:59: App.Facade.to_int_guarded/1` [38].
- Повторный `mix compile --warnings-as-errors` без изменений печатает прежние предупреждения и завершается с кодом 1:
  `Compilation failed due to warnings while using the --warnings-as-errors option` [38].

### Сверх списка

- **Больше 16 подходящих clauses с разными результатами** — результат `dynamic()` [8:16, 1852-1863][42]:
  - `evolve/2` из 20 clauses `def evolve(:state, %E22.EvN{}), do: {:state, :sN}`;
  - `case Big.evolve(:state, e)` с `:impossible ->` при параметре `e` молчит;
  - у `Small` из 3 clauses то же ловится;
  - при известном событии (`%E22.Ev1{}`) ловится;
  - неверный аргумент (`"not an event"`) ловится всегда.

  Clauses с одинаковым результатом (`{:state, integer()}`) слились в одну строку сигнатуры, и предел не наступает [42].
- **Первая ошибка в пути глушит следующие** [12:553-570][35]. В `a = Integer.to_string("a"); b = byte_size(1)`
  сообщена только первая. В разных ветвях `if` — обе.
- **Тесты с намеренно неверными типами** (`assert_raise FunctionClauseError, fn -> App.Local.to_int("x") end`)
  выдают предупреждения. `mix test --warnings-as-errors` при зелёных тестах завершается так:
  `ERROR! Test suite aborted after successful execution due to warnings while using the --warnings-as-errors option`
  [45].

## Runtime против compile-time

| Конструкция | Проверка при компиляции | Почему | Замена, проверенная экспериментом |
|---|---|---|---|
| Catch-all или `raise`-clause на неверный вход | аргументы — нет; результат `raise`-clause — да | clause с `term()` пересекается со всем [8:1852-1894] | убрать clause: неверный вызов ловится [28], остальное — `FunctionClauseError` |
| Catch-all из `@before_compile` | нет | то же | не генерировать [30] |
| Функция из `quote` под `@impl true` | да | обычная `def` [30] | — |
| Код с `generated: true` | внутренние предупреждения — нет | `warn`/`error` пропускают узел [12:535-570] | не размечать пользовательский код [30] |
| `mod.fun()` с `mod` из параметра, конфигурации, поля map-параметра | нет | `dynamic()` → модулей нет [10:712-724][8:1454-1456] | модуль литералом в месте вызова: `@attr`, `unquote(mod)` в `quote`, переменная с литералом, `when mod in [...]` [29][31] |
| `apply/3`, `Module.concat` | нет | `:erlang.apply/3 -> dynamic()` [8:161-162] | прямой вызов [29] |
| Обёртка или `defdelegate` на модуль того же проекта | вызов обёртки — нет | вывод пропускает удалённые вызовы [7:21-25][8:1544-1554] | паттерн/guard в голове обёртки: `to_int_guarded("x")` ловится [38]; обёртка на зависимость протекает сама [38] |
| Behaviour-колбэк через модуль-переменную | нет | см. `mod.fun()` | прямой вызов реализации [32] |
| `@spec`, `@callback` | не используются | не читаются [32][1:16] | в 1.20 нет |
| Функция протокола, интерполяция, `for` по struct | да, при консолидации | сигнатура консолидации [16:668-724] | не отключать консолидацию [41]; в umbrella её нет [24:175-183] |
| JSON, `Repo.get!`, поля Ecto-схемы | нет | `dynamic()` [33][40] | сопоставить форму на границе: `%Row{} = row = Repo.get!(…)`, `%{"k" => v} when is_integer(v)` [40][33] |
| Тип значения поля struct из параметра | ключ — да (при `%Mod{}`), значение — нет | поля `dynamic()`/`term()` [10:525-533][11:700-755] | паттерн поля в голове и операция над ним: `%Deposited{amount: a}` и `s.balance + a` дают домен `amount: float() or integer()`, вызов с `%Deposited{amount: "ten"}` ловится [34] |
| `is_struct/2`, `%{__struct__: M}`, `defguard` на их основе | ключи — только у вызывающего с известным struct | открытая map [17:2683-2689][11:757-787] | `%Mod{}` в голове [34][44] |
| `Access` (`x[:k]`), `Keyword.get/fetch!`, `Enum.at` | нет | результат `dynamic()` [33] | `.key`, `Map.get`, `Map.fetch!` на известной map [33] |
| `Access` на struct | нет; runtime `UndefinedFunctionError` | домен `Access.get/2` включает struct | `.key` [33] |
| `Map.put` нового ключа в struct | нет | результат — map | `%{s \| key: v}` ловит неизвестный ключ [34] |
| `Enum.*` с `fn`/захватом, элемент `for`-генератора | нет | параметры `fn` и элементы — `dynamic()` [9:498-515, 820-833] | не найдено: явная рекурсия тоже молчит [37] |
| Параметр-функция вызываемой функции | только арность и «это функция» | параметр `dynamic()` | `is_function(fun, n)` в голове [36] |
| Частично неверный union, неисчерпывающий `case` | нет | gradual: достаточно пересечения [13:964-978][9:970-971] | в 1.20 не найдено |
| Больше 16 clauses с разными результатами | аргументы — да; результат — только при узком аргументе | `@max_clauses 16` [8:16] | точный тип аргумента в месте вызова [42]; при одинаковом результате clauses сливаются [42] |
| Функции OTP вне встроенного списка | нет | нет `ExCk` [14:426-461][8:140-341] | — |
| `with`/`case` с `_ ->`, `try/rescue` | да | clauses проверяются по типу результата [9:430-496, 645-667] | — |
| Предупреждение типа не ломает сборку | — | — | `mix compile --warnings-as-errors` [38]; `mix test --warnings-as-errors` [45] |

## Расхождения источников и экспериментов

1. Документация: «calls to modules within the same project are assumed to be `dynamic()`» [1:234]. Эксперимент
   расходится: вызов `App.Local.to_int("x")` из другого модуля проекта ловится [38]. Так же ловится пример
   `User.name(%{})` из CHANGELOG [2:139-173]. Код объясняет расхождение: `dynamic()` появляется только при выводе
   сигнатур (`stack.mode == :infer`, `fetch_export(..., false)`), при проверке сигнатура берётся
   (`fetch_export(..., true)`) [8:1539-1583]. Фраза документа верна для вывода и неверна для проверки.
2. CHANGELOG 1.18: «Type checking of all language constructs … except `for`, `with`, and closures» [4:104] —
   устарело. `with` и замыкания проверяются [3:75-111][35][36]. У `for` проверяется перечислимость источника
   (консолидированный `Enumerable`) [38], тип элемента — нет [9:820-833][33].
3. Пост 2026-01-09 о rc.0: вывод через функции зависимостей ещё не выполняется [6:173-183]. В 1.20.3 выполняется
   [2:304][38]. Это исполненный план rc, а не противоречие.
4. `Map.get(%{amount: 1}, :amount)` получает тип `nil or integer()`, хотя ключ обязателен [33]. В документации и
   CHANGELOG объяснения этой потери точности не найдено.

## Не найдено / не проверено

- Umbrella-проект — только по коду (`consolidation_status :off`) [24:175-183].
- git- и hex-зависимости не проверялись, только path. По коду Mix одинаково берёт все зависимости с `app: true`
  [23:216-221].
- `receive`, `GenServer.call`, `send`, `Task` как источники `dynamic()` не исследовались. По коду clauses `receive`
  получают домен `dynamic()` [9:569-593].
- Подавление clauses в `case` по литералу или сгенерированному выражению [9:434-450] экспериментом не проверено.
- Влияние `module_definition: :interpreted` на вывод не исследовалось.
- Официального перечня того, что подавляет `generated: true`, в документации нет — только код [12:535-570][9:434-450][11:190].

## Источники

1. elixir-lang/elixir v1.20.3, `lib/elixir/pages/references/gradual-set-theoretic-types.md:12-16, 199-238, 240-282` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/pages/references/gradual-set-theoretic-types.md
2. elixir-lang/elixir v1.20.3, `CHANGELOG.md:11-173, 302-304` — https://github.com/elixir-lang/elixir/blob/v1.20.3/CHANGELOG.md
3. elixir-lang/elixir, ветка v1.19, `CHANGELOG.md:9-111` — https://github.com/elixir-lang/elixir/blob/v1.19/CHANGELOG.md
4. elixir-lang/elixir, ветка v1.18, `CHANGELOG.md:5-114` — https://github.com/elixir-lang/elixir/blob/v1.18/CHANGELOG.md
5. J. Valim, «Elixir v1.20 released: now a gradually typed language», 2026-06-03 (elixir-lang/elixir-lang.github.com, `src/content/blog/elixir-v1-20-0-released.md:30-94`) — https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/
6. J. Valim, «Type inference of all constructs and the next 15 months», 2026-01-09 (elixir-lang/elixir-lang.github.com, `src/content/blog/type-inference-of-all-and-next-15.md:137-203`) — https://elixir-lang.org/blog/2026/01/09/type-inference-of-all-and-next-15/
7. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types.ex:9-31, 37-130, 136-169, 219-290, 292-317, 520-570` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types.ex
8. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types/apply.ex:16, 89-93, 140-341, 354-367, 954-962, 1134-1470, 1524-1583, 1766-1775, 1852-1894` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types/apply.ex
9. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types/expr.ex:166-258, 430-496, 498-515, 517-567, 569-593, 645-667, 669-677, 723-727, 820-833, 902-918, 970-971` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types/expr.ex
10. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types/of.ex:259-299, 460-533, 712-724` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types/of.ex
11. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types/pattern.ex:183-219, 700-787` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types/pattern.ex
12. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types/helpers.ex:535-574` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types/helpers.ex
13. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/types/descr.ex:935-978, 1223-1238, 1421-1463` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/types/descr.ex
14. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/parallel_checker.ex:239-297, 426-461, 484-515, 546-601, 665-685` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/parallel_checker.ex
15. elixir-lang/elixir v1.20.3, `lib/elixir/lib/module/behaviour.ex:17-32` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/module/behaviour.ex
16. elixir-lang/elixir v1.20.3, `lib/elixir/lib/protocol.ex:628-724` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/protocol.ex
17. elixir-lang/elixir v1.20.3, `lib/elixir/lib/kernel.ex:2645-2691` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/kernel.ex
18. elixir-lang/elixir v1.20.3, `lib/elixir/lib/kernel/parallel_compiler.ex:457-477` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/kernel/parallel_compiler.ex
19. elixir-lang/elixir v1.20.3, `lib/elixir/lib/code.ex:1769-1775` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/lib/code.ex
20. elixir-lang/elixir v1.20.3, `lib/elixir/src/elixir_module.erl:197-206, 232-234, 593-607` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/src/elixir_module.erl
21. elixir-lang/elixir v1.20.3, `lib/elixir/src/elixir_erl.erl:652-674` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/src/elixir_erl.erl
22. elixir-lang/elixir v1.20.3, `lib/elixir/src/elixir_rewrite.erl:101-102` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/elixir/src/elixir_rewrite.erl
23. elixir-lang/elixir v1.20.3, `lib/mix/lib/mix/tasks/compile.elixir.ex:139-154, 194-222` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/mix/lib/mix/tasks/compile.elixir.ex
24. elixir-lang/elixir v1.20.3, `lib/mix/lib/mix/compilers/elixir.ex:175-183, 1157-1162, 1230-1267` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/mix/lib/mix/compilers/elixir.ex
25. elixir-lang/elixir v1.20.3, `lib/mix/lib/mix/compilers/test.ex:28-31` — https://github.com/elixir-lang/elixir/blob/v1.20.3/lib/mix/lib/mix/compilers/test.ex

Эксперименты — в `01-experiments/`
(далее `…/`). Компиляция: `elixirc <файл> -o outNN`, вывод — в `*.out`; сигнатуры — `elixir -pa outNN sig.exs Mod:fun/arity`.

26. `…/exp/sig.exs` — печать выведенных сигнатур из чанка `ExCk`
27. E01: `…/exp/e01_basics.ex`, `e01.out`
28. E02: `…/exp/e02_catch_all.ex`, `e02.out`, `e02_sigs.out`
29. E03: `…/exp/e03_dynamic_calls.ex`, `e03.out`
30. E04: `…/exp/e04_macros.ex`, `e04.out`
31. E04b: `…/exp/e04b_unquote_module.ex`, `e04b.out`, `e04b_sigs.out`
32. E05: `…/exp/e05_spec_callback.ex`, `e05.out`, `e05_sigs.out`
33. E07: `…/exp/e07_external_data.ex`, `e07.out`, `e07_sigs.out`
34. E09: `…/exp/e09_structs.ex`, `e09.out`, `e09_sigs.out`
35. E10: `…/exp/e10_control_flow.ex`, `e10.out`
36. E11: `…/exp/e11_funs.ex`, `e11.out`, `e11_sigs.out`
37. E11b: `…/exp/e11b_recursion.ex`, `e11b.out`, `e11b_sigs.out`
38. E12: `…/proj/app/` (path-зависимость `…/proj/dep_lib/`); `…/proj/e12_first.out` (первая версия `facade.ex`/`caller.ex` без `to_int_guarded` и `defdelegate`), `e12_final.out`, `e12_sigs.out`, `e12_incremental.out` (guard `App.Local.to_int/1` временно `is_binary`), `e12_wae.out`
39. E17: `…/exp/e17_private_clauses.ex`, `e17.out`
40. E18: `…/exp/e18_ecto.ex`, `e18.out`, `e18_sigs.out`; `-pa` на `_build/dev/lib/{ecto,ecto_sql,postgrex,db_connection,decimal,telemetry,jason}/ebin` проекта core-ex, только чтение
41. E19: `…/proj/e19_noconsol.out` — `mix compile --force --no-protocol-consolidation` в `…/proj/app`
42. E22: `…/exp/e22_max_clauses.ex`, `e22.out`, `e22_sigs.out`; `…/exp/e22b_same_return.ex`, `e22b_sigs.out`
43. E23: `…/exp/e23_partial_union.ex`, `e23.out`
44. E24: `…/exp/e24_misc.ex`, `e24.out`, `e24_sigs.out`
45. E25: `…/proj/app/test/types_test.exs`; `…/proj/e25_test.out` (третий тест — `assert App.Local.to_int(value) == "x"`), `e25_wae.out`, `e25_wae2.out` (все три теста — `assert_raise`)
46. `…/exp/runtime.out` — runtime-исход молчащих случаев из [29][33][36][43]
