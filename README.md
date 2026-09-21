# Core

Shared-фундамент Elixir-приложений: доменные примитивы, кодеки, репозитории поверх
PostgreSQL, event store, transactional outbox, адаптеры брокеров и PromEx-плагины.

Библиотека **host-agnostic**: она не знает ни имени приложения-потребителя, ни его
домена, ни его роутера с эндпоинтом. Всё, что ей нужно, приходит через конфигурацию
(`Core.Config`), опции макросов и `opts` OTP-процессов.

## Состав

| Namespace | Назначение |
|---|---|
| `Core.Prim.*`, `Core.Enum`, `Core.Validator.*` | доменные примитивы с валидацией и типами |
| `Core.Codec`, `Core.Codec.Facade`, `Core.Codec.Plugin`, `Core.Codec.Redump` | wire-профили и entity-фасады (dump/load) |
| `Core.Context`, `Core.Error`, `Core.Exc`, `Core.Result`, `Core.Option` | сквозные контракты вызова и ошибок |
| `Core.DAO` | билдер `Ecto.Repo` потребителя (обёртка транзакций под after-commit хуки) |
| `Core.Repo`, `Core.Repo.Pg*`, `Core.Repo.Sc` | контракт репозитория, реализация на Ecto/Postgres, shadow copy |
| `Core.Es.*` | доменные события и их wire-конверт, event-sourced агрегат и его write-репозиторий, event store, маппинг в outbox |
| `Core.Outbox.*` | transactional outbox: запись, поллер, доставка, чистильщик |
| `Core.Mq.*`, `Core.PubSub.*` | адаптеры RabbitMQ Stream / Kafka и контракты pub/sub (клиенты — опциональные зависимости, см. ниже) |
| `Core.Web.*` | граница HTTP: конверт ответа, разбор параметров, `%Error{}` → HTTP-статус, сервер метрик |
| `Core.Otel`, `Core.Otel.Messaging`, `Core.Otel.LogFilter` | пропагация OpenTelemetry через outbox и брокер, `trace_id` в metadata логов |
| `Core.Helper.*` | транзакции, savepoint, advisory-локи, after-commit хуки |
| `Core.*.PromEx` | плагины метрик для outbox, MQ, event sourcing, кешей, воркеров, cgroup |

## Подключение

```elixir
# mix.exs потребителя
{:core, git: "https://github.com/Aleksey1707/core-ex", tag: "v0.3.4"}
```

## Опциональные зависимости: адаптеры брокеров

Клиентские библиотеки брокеров объявлены `optional: true` и **не приходят потребителю
транзитивно**. Приложению, которому нужен только RabbitMQ Stream, не придётся собирать
`klife` с его нативными зависимостями (`crc32cer`, `snappyer` — NIF, требуют C-toolchain
в образе сборки), и наоборот.

| Нужен адаптер | Объявите у себя | Появятся модули |
|---|---|---|
| RabbitMQ Stream | `{:rabbitmq_stream, "~> 0.4.2"}` | `Core.Mq.Stream.Connection`, `Core.Mq.Stream.Reader` |
| Kafka | `{:klife, "~> 1.2"}` | `Core.Mq.Kafka.Writer` (только публикация) |
| ни одного | — | остальное работает как обычно |

Всё, что не зависит от конкретного клиента, компилируется всегда: `Core.Mq.Writer` /
`Core.Mq.ReaderReliable` (behaviour), `Core.Mq.Stream.Writer` (получает connection-модуль
в `opts`), `Core.Mq.Stream.Credentials`, `Core.Mq.Stream.Codec`, `Core.Outbox.Delivery.Mq`,
`Core.PubSub.*`, `Core.Mq.PromEx`. Свой адаптер под другой брокер подключается реализацией
behaviour — менять библиотеку для этого не нужно.

Контракты задают порядок и обработку ошибок, но **не** представление на проводе: оно —
свойство адаптера (`Core.Mq.Stream.Codec` заворачивает сообщение в JSON с base64-телом,
`Core.Mq.Kafka.Writer` пишет нативно). Потребители одного топика обязаны читать тем же
адаптером, каким он написан; подробности — `docs/rules/10-architecture.md`.

Читателя для Kafka в библиотеке нет: `Core.PubSub.MqSubscriberReliable` и путь DLQ
работают только поверх RabbitMQ Stream (`docs/rules/DEBT.md`).

Модули адаптеров объявлены под `if Code.ensure_loaded?/1`: без клиента их просто нет,
и обращение к ним даёт `UndefinedFunctionError`, а не ошибку компиляции библиотеки.

> **Клиент, добавленный после первой сборки.** Обычно достаточно `mix deps.get && mix compile`:
> Mix пересобирает зависимость, когда в том же прогоне собирает её optional-зависимость.
> Пересборки **не** будет, если клиент уже лежал собранным в `_build` (удалили и вернули,
> переключение веток) или `core` подключён как `path:`-зависимость (локальная разработка) —
> тогда адаптер останется отсутствующим, хотя клиент уже в `deps`:
> ```bash
> mix deps.compile core --force
> ```
> Удаление клиента адаптер из `_build` не убирает — он остаётся, пока `core` не пересоберётся.
> Оба расхождения ловит `ensure_available!/0` (см. «Проверка конфигурации на старте»).

## Конфигурация

Всё, что читает библиотека, лежит под её собственным приложением `:core`.

### Обязательные ключи

```elixir
config :core,
  otp_app: :my_app,
  dao: MyApp.DAO,
  codec: MyApp.Codec.Internal
```

| Ключ | Тип | Назначение |
|---|---|---|
| `otp_app` | `atom()` | приложение, в app-env которого потребитель держит свои DI-ключи «behaviour → реализация». Читается `Core.Config.repo!/1` на компиляции call site, поэтому задаётся в `config.exs`, а не в `runtime.exs`. Единственное место, где Core обращается к конфигурации не под `:core` |
| `dao` | `module()` | `Ecto.Repo` приложения |
| `codec` | `module()` | entity-фасад Codec для внутреннего wire (БД / outbox) |

### Опциональные ключи

| Ключ | Тип | Дефолт | Назначение |
|---|---|---|---|
| `tz` | `String.t()` | `"Etc/UTC"` | часовой пояс приложения (`datetime_tz: :app` в кодеках, `Prim.Date*`) |
| `telemetry_prefix` | `[atom()]` | `[otp_app()]` | префикс имён telemetry-событий Core |

### Подсистемы

```elixir
# Читается Core только ради `Poller.wake/1` после записи в очередь.
# Либо один поллер:
config :core, Core.Outbox, poller_name: MyApp.Outbox.Poller
# либо несколько, с разбиением по топикам:
config :core, Core.Outbox,
  pollers: [
    [name: MyApp.Outbox.Poller.Orders, topics: ["orders"]],
    [name: MyApp.Outbox.Poller.Rest, topics: :all]
  ]

# Ключ шифрования секретов (Fernet, 32 байта в base64). Обязателен, если используется
# `Core.Security.Secret`. Проверяется на старте — `Core.Security.Secret.ensure_configured!/0`.
config :core, Core.Security.Secret, secret_key: System.fetch_env!("SECRET_ENCRYPTION_KEY")
```

Остальные настройки outbox (интервалы, размер батча, TTL) библиотека не читает: они
приходят `opts`-ами в `Core.Outbox.Poller` / `Core.Outbox.Cleaner` от supervisor'а
потребителя. Где их держать и из каких env читать — конвенция приложения,
`deps/core/docs/rules/app/14-events-outbox.md`, «Конфигурация».

### Реализации репозиториев

Ключа не требуют: реализация выводится из имени behaviour по конвенции `<Behaviour>.Pg`
(`Core.Config.repo!/1`, `Core.Config.outbox_repo/0`). `config :core, Core.Outbox.Repo`
и `config :my_app, <Behaviour>` нужны только при подмене реализации — например тестовой
или in-memory. Решение и его цена — `docs/adr/0006-repo-impl-resolved-by-convention.md`.

### Проверка конфигурации на старте

```elixir
def start(_type, _args) do
  Core.Config.validate!()
  Core.Security.Secret.ensure_configured!()
  # опционально — только если приложение действительно поднимает адаптер:
  Core.Mq.Stream.ensure_available!()
  Core.Mq.Kafka.ensure_available!()
  # обязательно, если приложение ставит outbox в дерево:
  outbox = Application.get_env(:core, Core.Outbox, [])

  Core.Outbox.check_singleton!(
    enabled?: Keyword.get(outbox, :enabled, false),
    cluster_query: Application.get_env(:my_app, :dns_cluster_query),
    allow_cluster?: Keyword.get(outbox, :allow_cluster, false)
  )

  # обязательно, если поллеров несколько (конфиг `pollers`):
  Core.Outbox.validate_partition!(outbox[:pollers] || [])
  ...
end
```

`validate!/0` проверяет, что обязательные ключи заданы, `dao` и `codec` загружаются
и экспортируют нужные функции, а `tz` известен базе часовых поясов.

`Core.Outbox.check_singleton!/1` отказывает в старте, если outbox включён при заданной
кластеризации: каждая нода поднимет свой поллер, и порядок доставки нарушится.
`allow_cluster?: true` разрешает старт ценой порядка и пишет `warning`. Значения передаёт
приложение: ключ кластеризации — его, а не библиотеки.

`Core.Outbox.validate_partition!/1` отказывает в старте, если фильтры топиков двух
поллеров пересекаются: `FOR UPDATE SKIP LOCKED` защищает от дублей, но не от перестановки,
и общий топик у двух поллеров ломает порядок доставки молча.

`Core.Mq.Stream.ensure_available!/0` / `Core.Mq.Kafka.ensure_available!/0` — опциональные
проверки для тех, кто использует соответствующий адаптер. Различают два случая и дают
понятную ошибку при старте приложения, а не `UndefinedFunctionError` на первом вызове
адаптера в глубине supervisor-дерева: клиента нет в `deps`; клиент есть, но `core` собран
без него и не пересобран (`mix deps.compile core --force`). Звать только если адаптер
действительно используется.

## Что предоставляет потребитель

1. **`Ecto.Repo`** — через `Core.DAO`: это `use Ecto.Repo` плюс обёртка `transact/1,2`
   и `transaction/1,2` в `Core.Helper.AfterCommit.wrap/1`, без которой after-commit хуки
   (wake поллера outbox и читателей проекций, эталон `Repo.Sc` в `Repo.Pg.StateStored`) молча не
   выполняются:

   ```elixir
   defmodule MyApp.DAO do
     use Core.DAO,
       otp_app: :my_app,
       adapter: Ecto.Adapters.Postgres
   end
   ```

   Опции идут в `use Ecto.Repo` как есть; `otp_app:` и `adapter:` обязательны
   (`CompileError` при отсутствии).

2. **Codec-профили и фасады** — `use Core.Codec` для Prim-профилей, `use Core.Codec.Facade`
   для entity-фасадов. В список плагинов фасада **обязан** входить `Core.Outbox.Codec`,
   иначе `Core.Outbox.Repo.Pg.Schema` не сможет писать и читать записи очереди.
   Рабочий пример — `test/support/codec_fixture.ex`.

3. **Миграции.** DDL таблицы `outbox` живёт в `Core.Outbox.Migration`; потребитель заводит
   миграцию со своим timestamp и делегирует туда:

   ```elixir
   defmodule MyApp.Repo.Migrations.CreateOutbox do
     use Ecto.Migration

     defdelegate up, to: Core.Outbox.Migration
     defdelegate down, to: Core.Outbox.Migration
   end
   ```

   `mix ecto.migrate` работает без дополнительных путей, а изменение схемы приезжает с
   обновлением зависимости: миграция самой библиотеки (`priv/repo/migrations`) делегирует
   туда же, поэтому у потребителя накатывается ровно та схема, против которой гоняются её
   тесты. Колонки и состав индексов — контракт, имена индексов — нет.

   Хранилище событий `es_events`, снапшоты агрегатов `es_snapshots` и чекпоинты проекций
   `es_checkpoints` — так же, DDL всех трёх таблиц живёт в `Core.Es.Migration`:

   ```elixir
   defmodule MyApp.Repo.Migrations.CreateEsEvents do
     use Ecto.Migration

     defdelegate up, to: Core.Es.Migration
     defdelegate down, to: Core.Es.Migration
   end
   ```

   Строку `es_checkpoints` проекции, убранной из кода, удаляет миграция потребителя вместе с её
   таблицами — `Core.Es.Migration.delete_checkpoint/1`; библиотека строк сама не удаляет.

   Резервы изменяемых уникальных ключей event-sourced агрегатов `es_key_reservations`
   (`key_reservations:` у `use Core.Es.Aggregate.Repo.Pg`) — отдельной миграцией, DDL живёт в
   `Core.Es.KeyReservation.Migration`:

   ```elixir
   defmodule MyApp.Repo.Migrations.CreateEsKeyReservations do
     use Ecto.Migration

     defdelegate up, to: Core.Es.KeyReservation.Migration
     defdelegate down, to: Core.Es.KeyReservation.Migration
   end
   ```

   Вместе с ней приезжает `mix outbox.requeue --all` / `--id <uuid>` — возврат записей из
   `:failed` в очередь (runbook в `deps/core/docs/rules/app/14-events-outbox.md`). Задача поднимает
   приложение потребителя и берёт репозиторий из `Core.Config.outbox_repo/0`.

4. **DI репозиториев** — по конвенции, а не по конфигурации. Call site резолвит реализацию
   через `Core.Config.repo!/1`:

   ```elixir
   alias Core.Config

   require Config

   @repo Config.repo!(MyApp.Domain.Orders.Order.Repo)
   ```

   Без ключа берётся `MyApp.Domain.Orders.Order.Repo.Pg`. Ключ под своим `otp_app` нужен
   только при подмене:

   ```elixir
   config :my_app, MyApp.Domain.Orders.Order.Repo,
          MyApp.Domain.Orders.Order.Repo.Memory
   ```

   Прямой `Application.compile_env!/2` на доменный behaviour — нарушение
   (`docs/rules/13-repos.md`, «DI»). Проверяется линтером библиотеки, шагом вашего `make`:

   ```bash
   elixir deps/core/scripts/boundary_lint.exs --consumer lib test
   ```

5. **Supervision.** Библиотека не имеет своего OTP-приложения: `Core.Outbox.Poller`,
   `Core.Outbox.Cleaner`, `Core.Mq.Stream.Connection`, `Core.PubSub.MqSubscriberReliable`
   поднимает supervisor потребителя. Пример старта — `test/test_helper.exs`.

   Модуль доставки поллер берёт из опций, а не выводит из handle:

   ```elixir
   {Core.Outbox.Poller,
    repo: Core.Outbox.Repo.Pg,
    delivery_module: Core.Outbox.Delivery.Mq,
    delivery: Core.Outbox.Delivery.Mq.new(Core.Mq.Stream.Writer, MyApp.Outbox.Writer),
    poll_interval_ms: 1_000,
    idle_min_ms: 50,
    batch_size: Core.Outbox.BatchSize.new!(100),
    lock_duration: Core.Outbox.LockDuration.new!(60),
    max_attempts: Core.Outbox.Attempts.new!(10)}
   ```

   Проекции гоняет одно дерево `Core.Es.Projection.Supervisor` со всем списком проекций приложения
   на каждой ноде; опции и дефолты — в его moduledoc. Config и env библиотека не читает:
   рекомендуемые env — `ES_PROJECTIONS_*` в `config/runtime.exs`, длительности — через
   `Core.DurationParser`. Список и опции удобно собрать одной функцией — её же принимает
   `watch_list/1`:

   ```elixir
   # config/runtime.exs
   duration = &Core.DurationParser.to_timeout!(System.get_env(&1, &2))

   config :my_app, MyApp.Projections,
     enabled: System.get_env("ES_PROJECTIONS_ENABLED", "true") == "true",
     batch_size: String.to_integer(System.get_env("ES_PROJECTIONS_BATCH_SIZE", "100")),
     idle_min_ms: duration.("ES_PROJECTIONS_IDLE_MIN", "50ms"),
     poll_interval_ms: duration.("ES_PROJECTIONS_POLL_INTERVAL", "1s"),
     retry_min_ms: duration.("ES_PROJECTIONS_RETRY_MIN", "1s"),
     retry_max_ms: duration.("ES_PROJECTIONS_RETRY_MAX", "30s"),
     shutdown: duration.("ES_PROJECTIONS_SHUTDOWN", "30s"),
     await_min_ms: duration.("ES_PROJECTIONS_AWAIT_MIN", "10ms"),
     await_max_ms: duration.("ES_PROJECTIONS_AWAIT_MAX", "100ms"),
     notifications: System.get_env("ES_PROJECTIONS_NOTIFICATIONS", "true") == "true"

   # lib/my_app/projections.ex
   defmodule MyApp.Projections do
     def opts do
       [projections: [MyApp.Domain.Accounts.AccountList.Projection]] ++
         Application.fetch_env!(:my_app, __MODULE__)
     end
   end

   # MyApp.Application
   children = [MyApp.DAO, {Core.Es.Projection.Supervisor, MyApp.Projections.opts()}]
   ```

   `enabled: false` — дерево не стартует (`:ignore`); так ставится в `config/test.exs` вместе с
   `await: :inline`: тест прогоняет проекцию сам — `Core.Es.Projection.Test.run_until_idle/2`, а
   `Projection.await/3` в usecase прогоняет её в процессе теста.

   `notifications:` — сигнал чекпоинта между нодами: пачка шлёт `NOTIFY`, слушатель ноды держит
   по соединению на каждый различный `repo:` проекций — учтите их в лимитах базы и пулера. Одна
   нода — `false`: сигнала внутри ноды хватает. За pgbouncer в transaction mode `LISTEN` через
   пулер уведомлений не получает — keyword с прямым хостом, опции соединения поверх
   `repo.config()`: `notifications: [hostname: System.fetch_env!("DB_DIRECT_HOST")]`.

   Процесс event-sourced агрегата (`use Core.Es.Aggregate.Process`) — элемент `{Agg.Process,
   enabled: …}` на агрегат; опции и дефолты — в moduledoc `Core.Es.Aggregate.Process`. `enabled:`
   обязательна. `true` — дерево из `Registry` и `DynamicSupervisor`: команды агрегата идут в его
   процесс на id, который стартует в первой команде и уходит по простою; в `watch_list` плагина
   `Core.Workers.PromEx` — `Agg.Process.watch_list/1` с теми же опциями. `false` — элемент не
   стартует (`:ignore`), а `Agg.Process.execute` исполняет команду в вызывающем процессе — так
   ставится в тестах.

   ```elixir
   children = [MyApp.DAO, {MyApp.Domain.Accounts.Common.Account.Process, enabled: true}]
   ```

6. **Регистрация PromEx-плагинов** в модуле `use PromEx`:

   ```elixir
   def plugins do
     [
       {Core.Outbox.PromEx, poll_rate: 5_000},
       {Core.Mq.PromEx, poll_rate: 5_000, readers: {MyApp.PromEx.Mq, :readers, []}},
       {Core.Workers.PromEx, poll_rate: 5_000, watch: {MyApp.PromEx.Workers, :watch_list, []}},
       {Core.Cache.PromEx, poll_rate: 5_000, sizes: {MyApp.PromEx.Caches, :sizes, []}},
       {Core.Cgroup.PromEx, poll_rate: 5_000},
       {Core.Es.PromEx,
        poll_rate: 5_000,
        projections: {MyApp.Projections, :opts, []},
        processes: {MyApp.PromEx.Es, :processes, []}}
     ]
   end
   ```

   Читатели проекций в `watch:` — `Core.Es.Projection.Supervisor.watch_list(MyApp.Projections.opts())`:
   при `enabled: false` элементов нет, и нода без дерева не показывает `up=0`.

   `Core.Es.PromEx` без `projections:` и `processes:` строит только event-метрики. `projections:` —
   тот же провайдер опций дерева, что у `{Core.Es.Projection.Supervisor, MyApp.Projections.opts()}`:
   из него плагин берёт список проекций ноды для отставания, пересборки, `outdated` и сирот
   чекпоинтов. `processes:` — список модулей процесса агрегата:
   `def processes, do: [MyApp.Domain.Accounts.Common.Account.Process]`.

## Имена метрик

Telemetry-события Core называются `telemetry_prefix ++ suffix`. По умолчанию префикс —
`[otp_app()]`, то есть `[:my_app, :outbox, :poller, :cycle]`; он нужен собственным обработчикам
telemetry приложения. Имена метрик от него не зависят: плагины `Core.*.PromEx` строят их через
`PromEx.metric_prefix(otp_app, <плагин>)`, где `otp_app` — из `use PromEx` приложения
(`my_app_prom_ex_outbox_poller_cycles_total`), а переопределяет его опция плагина
`metric_prefix:`. Если приложение переезжает на библиотеку с уже работающими дашбордами,
сверьтесь с ними по этим именам. Рекомендованные алерты подсистем —
`docs/rules/21-observability.md`, «Рекомендованные алерты».

У `[:outbox, :poller, :cycle]` метка `result` принимает значения `:processed` / `:retry` /
`:idle` / `:error`. `:retry` — цикл дошёл до конца, но хоть одна запись пачки не
опубликована. Дашборд, считающий пропускную способность как `result="processed"`, частично
опубликованные пачки не увидит — суммируйте по `:processed` и `:retry`, а долю неудач
берите из `outbox_poller_retry_total` / `outbox_poller_failed_total`.

Gauge `outbox_queue_count{status}` выставляется для `:new`, `:in_work` и `:failed`.
`:published` не считается намеренно: это архив, ждущий TTL, единственный статус, растущий
неограниченно, и точный счёт по нему стоит скана всей таблицы на каждый опрос метрик
(замер на 400k строк: 28–40 мс против 0,14 мс по трём частичным индексам). Про запас
опубликованных говорят `outbox_cleaner_deleted_total` и размер таблицы.

Измерения `retry` и `failed` считаются по **записям пачки**, а не по повторам доставки:
при fail-stop весь хвост после сбойной записи возвращается в очередь и попадает в `retry`
(батч из 100 с ошибкой на первой записи даёт `retry = 100`). Это «не опубликовано в этом
цикле», а не «столько раз повторяли».

Метрики `Core.Es.PromEx` — `es_*` под префиксом PromEx (`my_app_prom_ex_es_projection_lag_seconds`):

| Метрика | Метки | Что это |
|---|---|---|
| `es_aggregate_load_total`, `es_aggregate_load_duration_milliseconds` | `type`, `op`, `result` | восстановление агрегата `get` / `get_decision` / `get_many` / `refresh`; `result`: `ok` / `version_mismatch` (у `get_decision` — сверка до решения) |
| `es_aggregate_fold_events` | `type`, `snapshot` | длина свёрнутого хвоста потока; `snapshot`: `hit` / `miss` / `rejected` / `off` — по ней выбирается `every:` |
| `es_snapshot_write_total`, `es_snapshot_write_duration_milliseconds` | `type`, `result` | запись снапшотов после commit; `result`: `ok` / `error` |
| `es_snapshot_write_rows_total` | `type` | записанные строки снапшотов |
| `es_projection_cycles_total`, `es_projection_duration_milliseconds` | `projection`, `result` | циклы читателя, включая холостые; `result`: `processed` / `idle` / `locked` / `retry` / `outdated` |
| `es_projection_events_total` | `projection` | события, прочитанные пачками |
| `es_projection_retry_total` | `projection`, `error` | отказы пачки с повтором; `error` — `ns/code` ошибки или модуль исключения |
| `es_projection_await_total`, `es_projection_await_duration_milliseconds` | `projection`, `result` | ожидание проекции; `result`: `ok` / `timeout` / `rebuilding` |
| `es_aggregate_process_execute_total`, `es_aggregate_process_execute_duration_milliseconds` | `type`, `mode`, `result` | команды процесса агрегата, длительность — с очередью; `result`: `ok` / `version_mismatch` / `error` / `exit` |
| `es_aggregate_process_execute_queue_milliseconds` | `type` | ожидание в очереди процесса на id (`mode="process"`) |
| `es_aggregate_process_execute_retries_total` | `type` | повторы команды после отказа записи |
| `es_aggregate_process_start_total`, `es_aggregate_process_stop_total` | `type`; у `stop` — `reason` | старт процесса на id и уход: `idle` / `error` |
| `es_projection_lag_seconds` | `projection` | отставание проекции |
| `es_projection_rebuilding` | `projection` | 1 — пересборка: строки чекпоинта нет, её версия ниже `version:` или чекпоинт ниже цели |
| `es_projection_outdated` | `projection` | 1 — версия строки чекпоинта выше `version:` кода этой ноды |
| `es_checkpoint_orphan` | `name` | по строке `es_checkpoints`: 1 — проекции с таким именем нет в списке ноды |
| `es_aggregate_processes` | `type` | процессы агрегата на id на ноде |

Отставание проекции — возраст самого раннего события её типов, которое она ещё не обработала:
первое событие каждого типа после чекпоинта (`LIMIT 1` по индексу `(тип, xid, номер)`) без
условия видимости пачки, так что событие за долгой транзакцией в отставании видно. Событий нет —
0; строки чекпоинта нет или её версия ниже `version:` — возраст первого события истории. При
пересборке отставание убывает и служит её прогрессом. Опрос — запрос на тип каждой проекции раз в
`poll_rate` на каждой ноде. `es_projection_outdated` и `es_aggregate_processes` — признаки ноды.
Серия `es_checkpoint_orphan` удалённой строки держит последнее значение до рестарта ноды.
Рекомендованные алерты — `docs/rules/22-projections.md`, «Эксплуатация».

## Трассировка

Библиотека зависит только от `opentelemetry_api`. Без установленного SDK её вызовы —
no-op: span'ы не создаются, заголовки не меняются, экспортёров и сетевых соединений
не появляется. SDK, exporter и автоинструментирование подключает потребитель.

Core закрывает то, чего не закрывает ни одна готовая интеграция, — **собственный
асинхронный транспорт**. Событие пишется в outbox внутри HTTP-запроса, публикуется
поллером через секунду в другом процессе, читается подписчиком в третьем; контекст
OTel живёт в process dictionary и сам туда не попадает. Переносит его `Core.Otel`:

Имена и структура спанов — по semantic conventions messaging (`Core.Otel.Messaging`):

| Точка | Что происходит |
|---|---|
| `Core.Es.Outbox.from_event/1` | `traceparent` текущего трейса кладётся в `headers` записи |
| `Core.Outbox.Delivery.Mq`, на сообщение | span `"create <topic>"` с родителем из записи; его контекст уходит в заголовки сообщения |
| `Core.Outbox.Delivery.Mq`, на пачку | span `"send <topic>"` (`kind: :producer`) со **ссылками** на create-спаны |
| `Core.PubSub.MqSubscriberReliable` | span `"process <topic>"` (`kind: :consumer`) с родителем из заголовков сообщения |

Собственный код потребителя, вызывающий `Core.Otel` напрямую, передаёт
`scope: <свой модуль>` — иначе его span'ы будут приписаны библиотеке.

Обязанности потребителя:

```elixir
# mix.exs
{:opentelemetry, "~> 1.5"},
{:opentelemetry_exporter, "~> 1.8"},
{:opentelemetry_phoenix, "~> 2.0"},
{:opentelemetry_ecto, "~> 1.2"},
{:opentelemetry_oban, "~> 1.1"},
```

```elixir
# MyApp.Application.start/2 — до старта supervision tree
OpentelemetryPhoenix.setup(adapter: :bandit)
OpentelemetryEcto.setup([:my_app, :dao], db_statement: :enabled)
OpentelemetryOban.setup()

# корреляция логов
:logger.add_primary_filter(:otel_trace, {&Core.Otel.LogFilter.filter/2, []})
```

```elixir
# config/config.exs
config :logger, :default_formatter, metadata: [:request_id, :trace_id, :span_id]
```

Логи в OTLP **не** уходят: экспортёр логов для BEAM не выпущен в hex
(`otel_log_handler` лежит в `opentelemetry_experimental` без экспортёра). Логи
остаются в stdout и собираются агентом (otel-collector `filelog`, Alloy, Vector);
с трейсом их связывает `trace_id` в metadata, который кладёт `Core.Otel.LogFilter`.
Метрики остаются в Prometheus через PromEx — OTel-метрики библиотека не вводит.

Пропагаторы выбирает потребитель. По умолчанию SDK ставит `[:trace_context, :baggage]`,
и тогда вместе с трейсом в строку outbox и в брокер уходит baggage целиком. Если это
нежелательно — `config :opentelemetry, text_map_propagators: [:trace_context]`.

## Разработка

```bash
make infra-up            # Postgres + RabbitMQ (podman compose, deploy/infra)
mix test                 # тесты; :rabbit_stream исключены по умолчанию
make test-stream         # включая тесты живого RabbitMQ Stream
make                     # rules-check → format-check → compile → compile-no-optional → deps-clean → xref → dialyzer → test → credo → audit
make compile-no-optional # сборка без optional-клиентов брокеров — так библиотеку видит потребитель без них
make infra-down
```

Свод правил, которым следует код библиотеки, — в `docs/rules/`: карта свода и стандарт его
оформления — `docs/rules/00-index.md`, осознанные отступления — `docs/rules/DEBT.md`,
проверка формы — `make rules-check`. Для агентов своды подключаются скиллами
`.claude/skills/*/SKILL.md`, точка входа — `AGENTS.md` (`CLAUDE.md` — симлинк на него).
