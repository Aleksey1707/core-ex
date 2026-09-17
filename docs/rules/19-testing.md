# Тесты

- **Область.** `test/**` библиотеки; у потребителя — его case-модули, фикстуры и тесты.
- **Читать перед.** Новым тестом или case-модулем; тестом кодека, репозитория, агрегата,
  процесса, Enum или события; правкой тестовой обвязки в `test/support`.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Case-модули

| Case | Когда |
|---|---|
| `ExUnit.Case` | чистые модули: Prim, Enum, Codec, хелперы |
| `Core.DataCase` | всё, что ходит в Postgres (Ecto Sandbox) |
| `Core.Es.EventCompatCase` | golden-фикстуры событий, один тест-модуль на агрегат (см. «Совместимость событий») |
| `Core.Es.ProjectionCase` | очистка `clear/0` проекции на golden-фикстурах, один тест-модуль на проекцию (см. «Проекции») |

У приложения-потребителя набор шире (`MyAppWeb.ConnCase`): web-слоя в библиотеке нет.

Тестовая обвязка библиотеки живёт в `test/support`: `Core.TestRepo` (роль `MyApp.DAO`),
`Core.CodecFixture.*` (роль `MyApp.Codec.*`), `Core.PrimFixture`, `Core.ViewFixture`,
`Core.MqFake`, `Core.EventFixture`, `Core.StateStoredFixture`, `Core.EsFixture`. Процессы,
которые в приложении поднимает его supervisor, стартуют в `test/test_helper.exs`.

`async: true` по умолчанию. `async: false` — только когда тест трогает глобальное состояние
(конфиг приложения, именованный процесс, консолидированные протоколы) и восстанавливает его
в `on_exit`. Явный `async:` требует `Credo.Check.Refactor.PassAsyncInTestCases`.

Фикстуры — доменные конструкторы (`<Aggregate>.new`, `test/support/prim_fixture.ex`), не Ecto
fixtures. Репозитории тестируются через behaviour: `@repo Config.repo!(Behaviour)`
(`13-repos.md`, «DI»). Подмена реализации на тестовую — ключом в `config/test.exs`, а не
другим call site.
При `shadow_copy?: true` контекст готовится как `Context.new() |> Repo.Sc.init()`.

## Codec: round-trip

`Repo.Pg.Schema.to_entity/to_model` пишутся руками, поэтому каждый Codec-плагин MUST иметь
round-trip-проверку `entity |> dump() |> load() == entity`.

- Примерный тест (один-два инстанса) — минимум.
- Property-based (`stream_data`) — для типов с комбинаторикой полей (шаги сообщения,
  настройки интегратора, nullable-поля): генератор доменных значений + `check all`.

Round-trip на текущем коде **не** ловит переименования: меняются обе стороны сразу.
От этого защищают golden-фикстуры (см. ниже).

### View: round-trip неприменим

`<Aggregate>.View.Codec` — dump-only (`loadable: false`), обратного преобразования у него нет.
Вместо round-trip MUST:

1. тест `<Aggregate>.ReadRepo.Pg.Schema.to_view/1` на полной строке — все колонки, включая
   nullable (тотальная функция: `nil` обязан пройти, а не упасть);
2. проверка формата `OutCodec.dump(view)` — id, даты и decimal совпадают с дампом
   соответствующего Prim (`OutCodec.dump(Agg.ID.new!(raw))` и т.п.), иначе wire read-пути
   молча разъедется с агрегатным;
3. `OutCodec.load(<Aggregate>.View, _)` поднимает `ArgumentError` — плагин остаётся dump-only.

### jsonb на read-пути: контракт wire

Полиморфная нагрузка (снимки, состояния шагов) переводится в формат внешнего профиля по
спеке `Core.Codec.Redump` (`13-repos.md`). Спека — декларация, и она обязана иметь
исполняемую проверку: `entity |> InCodec.dump() |> json_roundtrip() |> Redump.run(spec, OutCodec)`
MUST равняться `entity |> OutCodec.dump() |> json_roundtrip()`.

- `json_roundtrip` (`Jason.encode!` → `decode!`) обязателен: только он придаёт дампу ту
  форму, в которой jsonb реально возвращается из БД (строковые ключи, `Decimal` числом или
  строкой, `DateTime` строкой). Без него сверка идёт не с тем, что лежит в колонке.
- Проверка перебирает **весь набор** источников формы (`for step <- Step.Codec.steps()`),
  а не один пример: новый вариант нагрузки без объявленного формата обязан валить тест.
- Отдельным тестом — полнота декларации: у каждой нагрузки все поля с форматируемым Prim
  (`:uuid` / `:datetime` / `:date` / `:decimal`) объявлены (`wire_prims:`). Он даёт понятную
  ошибку раньше, чем расхождение дампов.

## Совместимость событий

Каждый агрегат с кодеком событий MUST иметь тест-модуль `use Core.Es.EventCompatCase` — один на
агрегат. Event-sourced агрегат передаётся `aggregate:` — case берёт его кодек; кодек state-stored
агрегата — `event_codec:`. Остальное case берёт из кодека и фасада `Core.Config.codec/0`. Каталог
фикстур, инварианты и правила эволюции — `14-events-outbox.md`, «Golden-фикстуры».

```elixir
# плохо — свой case: его проверки расходятся с кодеком библиотеки молча
use MyApp.EventCompatCase,
  codec: MyApp.Codec.Internal,
  event: Delivery.Event,
  aggregate_id: Delivery.ID

# хорошо — test/my_app/domain/<bc>/common/delivery/event_compat_test.exs
defmodule MyApp.Domain.<BC>.Common.Delivery.EventCompatTest do
  use Core.Es.EventCompatCase,
    event_codec: MyApp.Domain.<BC>.Common.Delivery.Event.Codec,
    async: true
end

# хорошо — test/my_app/domain/<bc>/common/account/event_compat_test.exs
defmodule MyApp.Domain.<BC>.Common.Account.EventCompatTest do
  use Core.Es.EventCompatCase,
    aggregate: MyApp.Domain.<BC>.Common.Account,
    async: true
end
```

## Event-sourced агрегат

Решения агрегата тестируются без БД, в `ExUnit.Case, async: true`:

- given — `Core.Es.Aggregate.Test.given(state, results, by:, at:)` от `%Agg{id: id}`: результаты
  `decide/2`, версии и `id` событий ставит библиотека; разные авторы — цепочкой вызовов;
- when — `Agg.decide(cmd, state)`;
- then SHOULD — короткая форма результата: `{:ok, [{Mod, payload}]}`, `{:ok, []}`,
  `{:error, %Error{kind: :domain, code: …}}` без `message` / `detail`.

Given из команд через `execute/2` SHOULD NOT: команда не воспроизводит событие удалённого типа,
а тест одной команды начинает зависеть от `decide` другой. Then по `%Es.Event{}` или по
состоянию после команды SHOULD NOT — `id` и `at` событий пришлось бы сверять в каждом тесте.

Применение событий — отдельные тесты `evolve` через `Agg.fold/2`; полноту `evolve` проверяет
сборка репозитория агрегата (`11-domain.md`, «Event-sourced»).

```elixir
# плохо — given командами: тест закрытия зависит от decide открытия и заморозки
{:ok, {_events, state}} = Account.execute(%Account{id: id}, %Cmd.Open{name: name, by: by, at: at})
{:ok, {_events, state}} = Account.execute(state, %Cmd.Freeze{by: by, at: at})

# хорошо
import Core.Es.Aggregate.Test, only: [given: 3]

state = given(%Account{id: id}, [{Event.Opened, payload}, Event.Frozen], by: by, at: at)

assert {:ok, [Event.Closed]} = Account.decide(%Cmd.Close{by: by, at: at}, state)
```

## Проекции

Каждая проекция MUST иметь тест-модуль `use Core.Es.ProjectionCase` — один на проекцию: он
проверяет на golden-фикстурах событий (`14-events-outbox.md`) норму `clear/0` из
`22-projections.md`, «Объявление», и сам находит таблицы, которые пишет проекция. Проверка, опции
и `async: false` — moduledoc `Core.Es.ProjectionCase`; полноту `project/1` проверяет сборка
проекции (`22-projections.md`, «Объявление»).

```elixir
# плохо — clear/0 проверен вручную: таблица, добавленная в проекцию позже, в перечень не попадёт
test "clear/0 очищает read-модель" do
  :ok = AccountList.Projection.project(opened)
  :ok = AccountList.Projection.clear()
  assert DAO.aggregate(AccountList.Row, :count) == 0
end

# хорошо — test/my_app/domain/<bc>/<actor>/account_list/projection_case_test.exs
defmodule MyApp.Domain.<BC>.<Actor>.AccountList.ProjectionCaseTest do
  use Core.Es.ProjectionCase,
    projection: MyApp.Domain.<BC>.<Actor>.AccountList.Projection,
    async: false
end
```

Проекцию SHOULD проверять записью через репозиторий агрегата → прогоном
`Core.Es.Projection.Test.run_until_idle/2` → чтением ReadRepo: так тест видит порядок событий
разных агрегатов, пропуск необъявленных тегов и апкаст. Прогон MUST идти в
`Core.DataCase, async: false`: блокировка пачки и строка чекпоинта держатся до конца
sandbox-транзакции, и пачка соседнего теста получила бы `{:error, :locked}`.

Прямой вызов `project/1` проекции MAY — в `async: true` на событиях из `Agg.execute/2` или
`events` state-stored агрегата; хелпера сборки событий нет.

```elixir
# плохо — прогон в async: true: пачку проекции держит sandbox-транзакция соседнего теста
use Core.DataCase, async: true

assert :ok = Core.Es.Projection.Test.run_until_idle(AccountList.Projection)

# хорошо — test/my_app/domain/<bc>/<actor>/account_list/projection_test.exs
use Core.DataCase, async: false

:ok = Accounts.Open.call(params, context)
assert :ok = Core.Es.Projection.Test.run_until_idle(AccountList.Projection)
assert {:ok, %AccountList.View{status: :open}} = AccountList.ReadRepo.get(id, :current, context)
```

Usecase с `Projection.await/3` тест SHOULD гонять на тестовом дереве `enabled: false`,
`await: :inline` из `config/test.exs`: `await` прогоняет проекцию до `:idle` в процессе теста,
как `run_until_idle`, и падает `RuntimeError` на `:locked`, `:outdated` и ошибке пачки. Такой
тест — тоже `Core.DataCase, async: false`.

```elixir
# плохо — тестовое дерево без await: :inline: читателей нет, чекпоинт стоит, await не дождётся
config :my_app, MyApp.Projections, enabled: false

# хорошо — config/test.exs
config :my_app, MyApp.Projections, enabled: false, await: :inline
```

## Enum: описания и внешние коды

`test/my_app/enum_docs_test.exs` — один тест на всё приложение: находит модули `Core.Enum`
(`values/0` + `cast_optional/1` без `new/1`) и сверяет таблицу значений в `@moduledoc`
с `values/0`. Не описанное значение и описанное несуществующее валят сборку. Конвенция
описаний — `11-domain.md`.

Enum с `codes:` MUST иметь round-trip по **всем** `values/0`
(`from_code(to_code(value)) == {:ok, value}`) и проверку нескольких известных кодов
против выгрузки источника. Round-trip сам по себе не ловит сдвиг нумерации: он проходит
и на выдуманных кодах, если они согласованы между собой.

У строковых кодов дополнительно проверяется, что совпадение точное (`"weight"` не проходит
за `"WEIGHT"`): молчаливая нормализация регистра свела бы два кода источника в один.

```elixir
test "коды справочника round-trip" do
  for value <- Type.values() do
    assert {:ok, ^value} = Type.from_code(Type.to_code(value))
  end
end

test "известные коды соответствуют справочнику" do
  assert {:ok, :railcar} = Type.from_code(2)
end
```

## Контрактные тесты behaviour

Если у behaviour больше одной реализации (`.Pg` и `.Cached`), общий набор тестов MUST лежать
в `test/support` и прогоняться на **каждой** реализации — иначе фасады расходятся молча.

```elixir
defmodule MyApp.ReadRepoContract do
  defmacro __using__(impl: impl), do: quote(do: @impl_mod unquote(impl))
  # ... общие тесты, работающие через @impl_mod
end
```

## `constraint_errors`

Маппинг DB-ограничения в доменный код — декларация, которая при расхождении с `changeset/2`
не падает: наружу уходит прикладной `%Error{kind: :app, code: :write_failed}` (500 и лог)
вместо доменного кода с текстом для клиента. Поэтому
`test/<app>/repo/constraint_errors_test.exs` (один на приложение) сверяет декларации с реальностью:

1. каждый ключ `constraint_errors` объявлен в `changeset/2` (сверка по `error_type`, не по типу
   ограничения — `foreign_key_constraint/3` пишет `:foreign`);
2. каждое ограничение `changeset/2` покрыто маппингом;
3. имена ограничений (`unique_constraint(name:)`, ключи `children:`) существуют в БД —
   `pg_constraint` плюс имена индексов, `unique_index` строки в `pg_constraint` не создаёт;
4. каждый FK дочерней таблицы, кроме колонки `fk:` на сам агрегат, покрыт маппингом.

Источник списка репозиториев — сгенерированные `__constraint_errors__/0` и
`__children_constraint_errors__/0`, а не ручной перечень: новый репозиторий попадает под
проверку сам.

## ACL

Каждый actor-репозиторий с `default_filters` под роль MUST иметь **negative**-тест: сущность
чужого владельца недоступна (`{:error, :not_found}`), а не «просто не появилась в списке».
Позитивный тест доступа сам по себе не доказывает, что фильтр работает.

## Время

Домен получает момент времени аргументом (`at`), а не читает часы внутри: `Es.Event.At.from(at)`,
`CreatedAt.from(at)`. `*.now()` вызывается на границе (usecase, воркер, OTP) — там его можно
подменить в тесте, передав явный `at`.

Тест MUST NOT зависеть от реального «сейчас»: сравнения дат — с зафиксированным значением,
переданным в конструктор.

## Oban

- Режим `testing: :manual`; постановка джобы проверяется `Oban.Testing.assert_enqueued/1`.
- Воркер с внешним эффектом MUST иметь тест на ключ идемпотентности: две постановки с
  одинаковыми `unique`-полями дают одну джобу (см. `14-events-outbox.md`).

## Процессы

- `Ecto.Adapters.SQL.Sandbox.allow(DAO, self(), pid)` для порождённых процессов, pid которых тест
  знает до их первого запроса.
- Процесс, который стартует внутри вызова (процесс агрегата на id при `{Agg.Process, enabled:
  true}`), тест MUST вести в shared mode sandbox — `async: false` на `Core.DataCase`
  (`start_owner!(shared: not async)`), без `allow` и `$callers`: pid появляется посреди вызова,
  который уже ждёт его запроса, и поставить `allow` некому.
- Циклы OTP проверять синхронным `run_once/1` (`Poller` / `Cleaner`), а не `sleep`
  в ожидании таймера.
- Тест, меняющий глобальный конфиг или именованный синглтон, — `async: false` с
  восстановлением в `on_exit`.
- Usecase с `Agg.Process.execute` тест потребителя SHOULD гонять на `{Agg.Process, enabled: false}`
  из дерева тестового окружения: команда идёт в процессе теста и в его sandbox, как вызов
  репозитория, без `allow`. Отметка старта глобальна — дерево ставит её один раз на прогон, а не
  тест.
- Устройство самих процессов — `17-otp-concurrency.md`.

```elixir
# плохо — процесс агрегата убран из тестового дерева: execute падает RuntimeError «не запущен»
children = [MyApp.DAO | if(test?, do: [], else: [{Account.Process, enabled: true}])]

# хорошо — дерево одно, config/test.exs выключает процесс: команда идёт в процессе теста
children = [MyApp.DAO, {Account.Process, Application.fetch_env!(:my_app, Account.Process)}]
config :my_app, Account.Process, enabled: false
```

```elixir
# плохо — allow на дерево: процесс на id стартует внутри execute под DynamicSupervisor, allow его
# не касается, и запрос процесса падает DBConnection.OwnershipError
{:ok, tree} = start_supervised({Account.Process, enabled: true})
Ecto.Adapters.SQL.Sandbox.allow(TestRepo, self(), tree)

# хорошо — async: false: Core.DataCase ставит shared mode, соединение теста видят все процессы
use Core.DataCase, async: false
{:ok, _tree} = start_supervised({Account.Process, enabled: true})
```

## Чувствительные данные

Проверка «секрет не утекает» (`refute inspect(...) =~ plaintext`) требует, чтобы Prim был
объявлен в `lib` или в `test/support`: протоколы консолидируются до старта тестов, и
`@derive Inspect` у модуля, объявленного внутри тест-файла, не действует. Чек-лист —
`12-errors.md`.

## Внешние зависимости

- Тесты, которым нужен живой брокер, — под тегом (`:rabbit_stream`), исключённым по умолчанию
  в `test/test_helper.exs`. Инфраструктура поднимается `make infra-up`.
- Конфигурационный контракт (`Core.Config`) проверяется отдельно, `test/core/config_test.exs`:
  такие тесты правят app env целиком, поэтому `async: false` с восстановлением в `on_exit`.

## Связанные правила

- Репозитории и Sandbox — `13-repos.md`
- События и идемпотентность — `14-events-outbox.md`
- Кеш и контрактные тесты фасадов — `deps/core/docs/rules/app/16-caching.md`
- OTP — `17-otp-concurrency.md`
