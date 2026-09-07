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
| `Core.Es.*` | доменные события и их wire-конверт, event store, маппинг в outbox |
| `Core.Outbox.*` | transactional outbox: запись, поллер, доставка, чистильщик |
| `Core.Mq.*`, `Core.PubSub.*` | адаптеры RabbitMQ Stream / Kafka и контракты pub/sub (клиенты — опциональные зависимости, см. ниже) |
| `Core.Web.*` | граница HTTP: конверт ответа, разбор параметров, `%Error{}` → HTTP-статус, сервер метрик |
| `Core.Otel`, `Core.Otel.Messaging`, `Core.Otel.LogFilter` | пропагация OpenTelemetry через outbox и брокер, `trace_id` в metadata логов |
| `Core.Helper.*` | транзакции, savepoint, advisory-локи, after-commit хуки |
| `Core.*.PromEx` | плагины метрик для outbox, MQ, кешей, воркеров, cgroup |

## Подключение

```elixir
# mix.exs потребителя
{:core, git: "https://github.com/Aleksey1707/core-ex", tag: "v0.1.0"}
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
| `otp_app` | `atom()` | приложение, в app-env которого потребитель держит свои DI-ключи «behaviour → реализация». Читается только макросом `use Core.Repo.Pg.Es` при резолве `event_repo:`. Единственное место, где Core обращается к конфигурации не под `:core` |
| `dao` | `module()` | `Ecto.Repo` приложения |
| `codec` | `module()` | entity-фасад Codec для внутреннего wire (БД / outbox) |

### Опциональные ключи

| Ключ | Тип | Дефолт | Назначение |
|---|---|---|---|
| `tz` | `String.t()` | `"Etc/UTC"` | часовой пояс приложения (`datetime_tz: :app` в кодеках, `Prim.Date*`) |
| `telemetry_prefix` | `[atom()]` | `[otp_app()]` | префикс имён telemetry-событий Core |

### Подсистемы

```elixir
# Реализация репозитория outbox. Обязателен, если используются Outbox или Repo.Pg.Es.
config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg

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
потребителя, поэтому храните их там, где вам удобно.

### Проверка конфигурации на старте

```elixir
def start(_type, _args) do
  Core.Config.validate!()
  Core.Security.Secret.ensure_configured!()
  # опционально — только если приложение действительно поднимает адаптер:
  Core.Mq.Stream.ensure_available!()
  Core.Mq.Kafka.ensure_available!()
  # обязательно, если поллеров несколько (конфиг `pollers`):
  Core.Outbox.validate_partition!(
    Application.get_env(:core, Core.Outbox, [])[:pollers] || []
  )
  ...
end
```

`validate!/0` проверяет, что обязательные ключи заданы, `dao` и `codec` загружаются
и экспортируют нужные функции, а `tz` известен базе часовых поясов.

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
   (wake поллера outbox, эталон `Repo.Sc` в `Repo.Pg.Es`) молча не выполняются:

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

3. **Ecto-тип jsonb** для колонки `payload` в схемах событий (`payload_type:`) —
   см. `test/support/test_types.ex`.

4. **Миграции.** Таблица `outbox` описана в `priv/repo/migrations` — это исполняемая
   спецификация: колонки и состав индексов обязаны совпадать, имена индексов — нет.
   Таблицы событий агрегатов создаёт потребитель (`table:` у `Core.Es.Event.Repo.Pg.Schema`).

   Вместе с ней приезжает `mix outbox.requeue --all` / `--id <uuid>` — возврат записей из
   `:failed` в очередь (runbook в `docs/rules/14-events-outbox.md`). Задача поднимает
   приложение потребителя и берёт репозиторий из `config :core, Core.Outbox.Repo`.

5. **DI-ключи под своим `otp_app`** — реализации доменных behaviour:

   ```elixir
   config :my_app, MyApp.Domain.Orders.Order.Event.Repo,
          MyApp.Domain.Orders.Order.Event.Repo.Pg
   ```

6. **Supervision.** Библиотека не имеет своего OTP-приложения: `Core.Outbox.Poller`,
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

7. **Регистрация PromEx-плагинов** в модуле `use PromEx`:

   ```elixir
   def plugins do
     [
       {Core.Outbox.PromEx, poll_rate: 5_000},
       {Core.Mq.PromEx, poll_rate: 5_000, readers: MyApp.PromEx.Workers.readers()},
       {Core.Workers.PromEx, poll_rate: 5_000, watch: {MyApp.PromEx.Workers, :watch_list, []}},
       {Core.Cache.PromEx, poll_rate: 5_000, sizes: {MyApp.PromEx.Caches, :sizes, []}},
       {Core.Cgroup.PromEx, poll_rate: 5_000}
     ]
   end
   ```

## Имена метрик

События Core называются `telemetry_prefix ++ suffix`. По умолчанию префикс — `[otp_app()]`,
то есть `[:my_app, :outbox, :poller, :cycle]`. Если приложение переезжает на библиотеку
с уже работающими дашбордами, задайте `telemetry_prefix` явно и сверьтесь с ними.

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
