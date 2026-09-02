# Core

Shared-фундамент Elixir-приложений: доменные примитивы, кодеки, репозитории поверх
PostgreSQL, event store, transactional outbox, адаптеры брокеров и PromEx-плагины.

Библиотека **host-agnostic**: она не знает ни имени приложения-потребителя, ни его
домена, ни web-слоя. Всё, что ей нужно, приходит через конфигурацию (`Core.Config`),
опции макросов и `opts` OTP-процессов.

## Состав

| Namespace | Назначение |
|---|---|
| `Core.Prim.*`, `Core.Enum`, `Core.Validator.*` | доменные примитивы с валидацией и типами |
| `Core.Codec`, `Core.Codec.Facade`, `Core.Codec.Plugin`, `Core.Codec.Redump` | wire-профили и entity-фасады (dump/load) |
| `Core.Context`, `Core.Error`, `Core.Exc`, `Core.Result`, `Core.Option` | сквозные контракты вызова и ошибок |
| `Core.Repo`, `Core.Repo.Pg*`, `Core.Repo.Sc` | контракт репозитория, реализация на Ecto/Postgres, shadow copy |
| `Core.Es.*` | доменные события, event store, маппинг в outbox |
| `Core.Outbox.*` | transactional outbox: запись, поллер, доставка, чистильщик |
| `Core.Mq.*`, `Core.PubSub.*` | адаптеры RabbitMQ Stream / Kafka и контракты pub/sub (клиенты — опциональные зависимости, см. ниже) |
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
| Kafka | `{:klife, "~> 1.2"}` | `Core.Mq.Kafka.Writer` |
| ни одного | — | остальное работает как обычно |

Всё, что не зависит от конкретного клиента, компилируется всегда: `Core.Mq.Writer` /
`Core.Mq.Reader` (behaviour), `Core.Mq.Stream.Writer` (получает connection-модуль в `opts`),
`Core.Mq.Stream.Credentials`, `Core.Mq.Codec`, `Core.Outbox.Delivery.Mq`, `Core.PubSub.*`,
`Core.Mq.PromEx`. Свой адаптер под другой брокер подключается реализацией behaviour —
менять библиотеку для этого не нужно.

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
  ...
end
```

`validate!/0` проверяет, что обязательные ключи заданы, `dao` и `codec` загружаются
и экспортируют нужные функции, а `tz` известен базе часовых поясов.

`Core.Mq.Stream.ensure_available!/0` / `Core.Mq.Kafka.ensure_available!/0` — опциональные
проверки для тех, кто использует соответствующий адаптер. Различают два случая и дают
понятную ошибку при старте приложения, а не `UndefinedFunctionError` на первом вызове
адаптера в глубине supervisor-дерева: клиента нет в `deps`; клиент есть, но `core` собран
без него и не пересобран (`mix deps.compile core --force`). Звать только если адаптер
действительно используется.

## Что предоставляет потребитель

1. **`Ecto.Repo`** — с `transact`, обёрнутым в `Core.Helper.AfterCommit.wrap/1`,
   иначе не сработают after-commit хуки:

   ```elixir
   defmodule MyApp.DAO do
     use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres

     defoverridable transact: 1, transact: 2

     def transact(fun_or_multi, opts \\ []) do
       Core.Helper.AfterCommit.wrap(fn -> super(fun_or_multi, opts) end)
     end
   end
   ```

2. **Codec-профили и фасады** — `use Core.Codec` для Prim-профилей, `use Core.Codec.Facade`
   для entity-фасадов. В список плагинов фасада **обязан** входить `Core.Outbox.Codec`,
   иначе `Core.Outbox.Repo.Pg.Schema` не сможет писать и читать записи очереди.
   Рабочий пример — `test/support/codec_fixture.ex`.

3. **Ecto-тип jsonb** для колонки `payload` в схемах событий (`payload_type:`) —
   см. `test/support/test_types.ex`.

4. **Миграции.** Таблица `outbox` описана в `priv/repo/migrations` — это исполняемая
   спецификация: колонки и состав индексов обязаны совпадать, имена индексов — нет.
   Таблицы событий агрегатов создаёт потребитель (`table:` у `Core.Es.Event.Repo.Pg.Schema`).

5. **DI-ключи под своим `otp_app`** — реализации доменных behaviour:

   ```elixir
   config :my_app, MyApp.Domain.Orders.Order.Event.Repo,
          MyApp.Domain.Orders.Order.Event.Repo.Pg
   ```

6. **Supervision.** Библиотека не имеет своего OTP-приложения: `Core.Outbox.Poller`,
   `Core.Outbox.Cleaner`, `Core.Mq.Stream.Connection`, `Core.PubSub.MqSubscriberReliable`
   поднимает supervisor потребителя. Пример старта — `test/test_helper.exs`.

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

## Разработка

```bash
make infra-up            # Postgres + RabbitMQ (podman compose, deploy/infra)
mix test                 # тесты; :rabbit_stream исключены по умолчанию
make test-stream         # включая тесты живого RabbitMQ Stream
make                     # format-check → compile → compile-no-optional → deps-clean → xref → dialyzer → test → credo → audit
make compile-no-optional # сборка без optional-клиентов брокеров — так библиотеку видит потребитель без них
make infra-down
```

Свод правил, которым следует код библиотеки, — в `.claude/rules/`.

## Миграция приложения на библиотеку

Чек-лист для приложения, у которого Core лежит внутри (`MyApp.Core.*`):

1. Добавить `{:core, git: ..., tag: ...}` в `deps`.
2. Удалить `lib/my_app/core/`, `lib/my_app/core.ex` и `test/my_app/core/`.
3. Переименовать `MyApp.Core.*` → `Core.*` по всему дереву
   (`grep -rl 'MyApp\.Core' | xargs sed -i 's/\bMyApp\.Core\b/Core/g'`).
4. Перенести настройки: `config :my_app, MyApp.Core, dao:/codec:/tz:` →
   `config :core, otp_app: :my_app, dao:, codec:, tz:`;
   `config :my_app, MyApp.Core.Outbox*` → `config :core, Core.Outbox*`;
   `config :my_app, MyApp.Core.Security.Secret` → `config :core, Core.Security.Secret`.
   DI-ключи доменных репозиториев остаются под `:my_app`.
5. Задать `telemetry_prefix: [:my_app]`, если имена метрик должны сохраниться.
6. Снять boundary-декларацию `MyApp.Core` и убрать её из `deps:` остальных boundary:
   инвариант «Core абстрактен» теперь обеспечен границей приложений.
7. Убрать зависимости, ставшие транзитивными (те, что использовал только Core:
   `argon2_elixir`, `fernetex`, `rabbitmq_stream`, `klife`, …) — сверьтесь с
   `mix deps.unlock --unused`.
8. Перемерить храповик `mix xref graph --format cycles`: часть циклов уходит вместе с Core.
