# Готовые ES-библиотеки на Elixir и совместимость с принципами `:core`

Исследование на 2026-09-13. Код читался на: eventstore `v1.4.8` (`0bf4f2e`), commanded `v1.4.11` (`91d97bc`),
commanded-eventstore-adapter `v.1.4.2` (`7f34860`), maestro master `ed860f3` (тегов нет), ariadne_flow
(`modell-aachen/flow`) main `ba17a65` (день релиза 0.10.1), spector `43c7629`, ash_events `56e30e8`.
«Вывод из кода» — следствие, которого в тексте источника нет. Схема хранения, глобальный порядок, проекции,
апкастинг, контракт агрегата и снапшоты Commanded/EventStore — в отчётах [01](01-event-store-schema.md),
[02](02-projections.md), [03](03-upcasting.md), [04](04-aggregate-snapshots.md); здесь не повторяются.

## Вопрос

[Тикет](../issues/11-research-es-libraries.md): какие живые Elixir-библиотеки event sourcing с PostgreSQL можно
положить под event-sourced агрегат `:core` и что каждая требует: транзакция с Ecto-репозиторием потребителя,
процессы агрегата, конфигурация и компиляция, точки расширения (сериализатор, wire-тег, метаданные, ошибки,
telemetry), совместимость и лицензия.

## Кандидаты

Поиск — hex.pm API по «event sourcing», «event store», «eventsourcing», «cqrs», «decider», «projection»,
«dcb» и GitHub по `language:Elixir` [21].

| Библиотека | Последний релиз | Активность | Лицензия | Роль |
|---|---|---|---|---|
| `eventstore` | 1.4.8, 2025-03-06 | 7 коммитов в master после релиза, последний 2026-05-04 [8] | MIT | event store на PostgreSQL |
| `commanded` | 1.4.11, 2026-07-27 | релизы 2025-09, 2026-05, 2026-07 [9] | MIT | CQRS/ES-фреймворк |
| `commanded_eventstore_adapter` | 1.4.2, 2024-10-25 | коммитов после релиза нет [14] | MIT | мост Commanded → EventStore |
| `commanded_ecto_projections` | 1.4.0, 2024-01-18 | последний push 2025-02-26 [21] | MIT | проекции (см. 02) |
| `maestro` | 1.0.0, 2026-07-07 | 0.3.4 (2019) → 0.4.0 (2025-08) → 1.0.0; 19 коммитов за год [9][17] | Apache-2.0 | агрегат + store на Ecto |
| `ariadne_flow` | 0.10.1, 2026-08-19 | единственный релиз на hex; 63 коммита за год [9][18] | Apache-2.0 | DCB-store на Ecto |
| `spector` | 0.8.0, 2026-02-27 | 64 коммита за год [9][19] | MIT | журнал изменений Ecto-схем |
| `ash_events` | 0.8.1, 2026-09-12 | 102 коммита за год [9][20] | MIT | журнал событий Ash-ресурсов |

**Живые, но без PostgreSQL-store:** `sourced` 0.2.0 (DCB, только InMemory-адаптер), `orkestra` 0.2.3 (store —
EventStoreDB и InMemory), `hume` (ETS), `derive` (проекции из своей таблицы), `scriba` (проекции для Commanded),
`counterpoint` (FoundationDB), `reckon_db`/`evoq`/`ex_esdb` (Khepri), `extreme`/`commanded_spear_adapter`
(EventStoreDB), `eventsourcingdb`, `cratis_chronicle`, `eventodb_ex`, `fact`; Gleam-пакеты
`eventsourcing_postgres`, `factos_pog`, `signal_pgo`; `ming` (CQRS без store), `ex_sorcery` (без зависимостей
от Ecto/Postgrex) [21].

**Мёртвые (нет релизов и коммитов 2+ года):** `incident` (2022-10), `cqrs_tools` (2022-02), `blunt` (2022-02),
`eventize` (2023-01), `backstage` (2024-09-08), `message_store` (2022), `seven` (2021), `perspective`, `drain`
(2020), `helios`, `rill`, `event_bus_postgres` (2019), `chronik`, `eidetic`, `disco` (2018), `estore`,
`workflow`, `engine`, `eventsourced` (2016–2017) [21].

## EventStore (без Commanded)

**Процессы.** OTP-приложение `:eventstore` стартует `Config.Store` (ETS) и `Registry` [2]. `MyApp.EventStore`
как child запускает `EventStore.Supervisor` (`one_for_all`) [2]:

- Postgrex-пул (`pool_size` 10);
- отдельное соединение `pool_size: 1` для advisory locks и процесс `AdvisoryLocks`;
- PubSub, `Subscriptions.Supervisor`, `Registry`;
- `Notifications.Supervisor`: `Postgrex.Notifications`, GenStage `Listener` и `Publisher`.

Опции, отключающей notifications или advisory locks, в supervisor нет — вывод из кода. `shared_connection_pool`
делит пул между инстансами store [1][2].

**Append/read без подписок.** `append_to_stream`, `read_stream_forward`, `stream_forward`, `record_snapshot`
берут соединение из `opts[:conn]`, иначе из конфигурации store. Конфигурация ищется через `Config.lookup(name)`
всегда, а lookup бросает «could not lookup … because it was not started» [1][2]. Значит, supervisor store должен
быть запущен и с `conn:` — вывод из кода.

**Транзакция.** Moduledoc, раздел «Using an existing database connection or transaction»: `:conn` — Postgrex-
соединение или транзакция, в том числе Ecto [1]:

```elixir
Repo.transaction(fn ->
  %{pid: pool} = Ecto.Adapter.lookup_meta(Repo)
  conn = Process.get({Ecto.Adapters.SQL, pool})
  :ok = EventStore.append_to_stream(stream_uuid, expected_version, events, conn: conn)
end)
```

- Меньше 1000 событий — одна CTE без своей транзакции; от 1000 — `Postgrex.transaction(conn, …)` на переданном
  соединении [3].
- `unique_violation` превращается в `{:error, :wrong_expected_version}` [4]. Вывод из кода и семантики PostgreSQL:
  после ошибки SQL внешняя транзакция в состоянии aborted, поэтому повтор `maybe_retry_once` на
  `:duplicate_stream_uuid` на том же `conn` [3] и остальные запросы usecase не пройдут.
- `NOTIFY` из триггера доставляется, только если транзакция закоммичена [16]: подписки увидят события после
  commit usecase.
- Persistent-подписки (`subscribe_to_stream`) берут `conn` только из конфигурации store, `ack` — сообщение
  процессу подписки [1]. Чекпоинт подписки в транзакцию потребителя не попадает — вывод из кода.
- Строка `$all` заблокирована до commit внешней транзакции — [01](01-event-store-schema.md).

**Конфигурация и компиляция.**

- `use EventStore, otp_app:` на компиляции требует только `otp_app` (`Keyword.fetch!`) [1].
- Конфигурация собирается при старте: `Application.get_env(otp_app, module)`, опции `start_link` и `init/1` [2].
- `:serializer` обязателен, иначе `ArgumentError` [5]. `schema:` задаётся в `use`, в конфиге или в `init/1`;
  несколько store в одной БД — в разных схемах [1].
- `column_data_type`: `"bytea"` (по умолчанию) или `"jsonb"`; значение попадает в DDL при init [2][6].
- Mix-задачи `event_store.create/init/migrate/drop` находят store по `-e` или `config :my_app, event_stores: […]`
  и вызывают `event_store.config()` [6]. В release — `EventStore.Tasks.Migrate.exec(config, [])` [6].
- Версия схемы БД — таблица `schema_migrations` и SQL-файлы `priv/event_store/migrations/v*.sql` (последний
  `v1.3.2`). Migrate идемпотентен, выполняется под advisory lock [6].
- Модуль store определяет потребитель. Адаптер Commanded получает его опцией `event_store:` и проверяет
  `@behaviour EventStore` [14].

**Формат события.**

- `EventData`: `event_id`, `correlation_id`, `causation_id`, `event_type`, `data`, `metadata` [5].
  `RecordedEvent` добавляет `event_number`, `stream_uuid`, `stream_version`, `created_at` [5].
- `event_type` — любая строка. Если он `nil`, а `data` — struct, пишется `Atom.to_string(module)` [3].
- Behaviour сериализатора: `serialize(term) :: binary | map`, `deserialize(binary | map, config)`. При чтении
  `data` получает `type: event_type`, `metadata` — `[]` [5].
- Встроенные сериализаторы: `JsonSerializer` (`String.to_existing_atom(type) |> struct(Jason.decode!(…,
  keys: :atoms!))`) и `JsonbSerializer`. По умолчанию — Erlang term format, «not recommended for production
  usage» [5].
- `created_at` = `DateTime.utc_now()` приложения или `created_at_override` (с 1.4.7), одно значение на весь
  вызов [3][8].
- `stream_version` назначает store: текущая версия потока + индекс события [3].

**Ошибки.** Все — `{:error, _}` с атомом [1][3][4]:

- `:wrong_expected_version`, `:stream_exists`, `:stream_not_found`, `:stream_deleted` (01);
- `:duplicate_event` (PK `events` / `stream_events`), `:not_found` (FK);
- `{:already_retried_once, :duplicate_stream_uuid}`;
- код ошибки PostgreSQL атомом;
- `:cannot_append_to_all_stream`.

**Telemetry.** Вызовов `:telemetry` в `lib` нет, в deps пакета нет [7]. Issue «Telemetry» #163 открыт
с 2019-04 [8].

**Совместимость.**

- `elixir: "~> 1.11"`; CI — Elixir 1.13–1.17 и `postgres:12`; README — «PostgreSQL v9.5 or newer» [7].
- Зависимости: `fsm ~> 0.3` (последний релиз 2018-06-14), `gen_stage`, `postgrex ~> 0.17`; optional — `jason`,
  `poolboy` [7][9].
- В master после 1.4.8 [8]:
  - правка предупреждений о синтаксисе комментариев;
  - документация notifications;
  - тип колонок correlation/causation (`4a88a29`).
- Открыты PR «Fix warnings» (#319, 2026-02) и issue #309: notifications теряются при `auto_reconnect: true` [8].

## Commanded + commanded_eventstore_adapter

**Обязательные части.** `use Commanded.Application, otp_app:` и `router(…)`. `start_link` запускает
`Commanded.Application.Supervisor` (`one_for_one`) [10][14]:

- child spec адаптера — для EventStore это `[{event_store, config}]`;
- pubsub и registry (по умолчанию `:local`);
- `Task.Supervisor` диспетчера, `Aggregates.Supervisor`, `Subscriptions.Registry`, `Subscriptions`.

Конфигурация приложения лежит в ETS `Commanded.Application.Config`. `Commanded.EventStore.*` находит адаптер через
`Config.get(application, :event_store)`, и lookup бросает исключение, если приложение не запущено [10][12].

**Путь команды.**

- `Dispatcher` вызывает `Aggregates.Supervisor.open_aggregate` и `Aggregate.execute` в
  `Task.Supervisor.async_nolink` [11].
- Процесс агрегата вызывает `execute(state, command)`, сворачивает события `apply/2` и пишет
  `EventStore.append_to_stream(application, aggregate_uuid, expected_version, event_data)` без opts [11].
- На `:wrong_expected_version` процесс дочитывает поток и повторяет команду, пока есть попытки, затем
  `{:error, :too_many_attempts}` [11].
- Публичной функции «выполнить команду над состоянием без процесса» нет. `Commanded.Aggregate.Multi.run/1`
  публичен, `AggregateCase` лежит вне компилируемых путей (04) — вывод из кода.

**Транзакция.** Процесс агрегата пишет в своём процессе на пуле store. Транзакция DBConnection привязана
к процессу, поэтому append идёт вне транзакции вызывающего — вывод из кода. `Commanded.EventStore.append_to_stream/5`
передаёт `opts` адаптеру, адаптер — в `event_store.append_to_stream`, добавив `name:` [12][14]. `conn:` дошёл бы
до EventStore, но это прямая запись мимо агрегата, и приложение всё равно должно быть запущено (вывод из кода).

**Конфигурация и компиляция.**

- `compile_config/2` выполняется в теле модуля приложения при компиляции: `Application.get_env(otp_app,
  application, [])` сливается с опциями `use` в `@config` [10].
- `runtime_config` сливает `@config` с опциями `start_link` и `init/1` и app env заново не читает [10]. Вывод
  из кода: значения из `runtime.exs` видны только через `init/1` или опции старта. Гайд: «optional `init/1`
  function to provide runtime configuration» [13].
- TypeProvider — `Application.get_env(:commanded, :type_provider, ModuleNameTypeProvider)` в рантайме: один на VM
  и на все приложения Commanded [12].

**Формат события.**

- `Mapper.map_to_event_data`: `event_type = TypeProvider.to_string(event)`, `data` — struct события, `metadata` —
  из опций dispatch, `causation_id`/`correlation_id` — из контекста [12]. С 1.4.10 опция dispatch `:causation_id`
  сохраняется; раньше её перетирал UUID команды [13].
- `ModuleNameTypeProvider`: `"Elixir.An.Event"` ↔ `String.to_existing_atom |> struct()` [12].
- Сериализатор задаётся у EventStore; для Commanded рекомендован `Commanded.Serialization.JsonSerializer` [1].
  Адаптер копирует поля без изменений [14].
- Своё wire-имя — только через свой TypeProvider, глобальный на VM (вывод из кода).

**Ошибки.**

- Adapter behaviour: `append_to_stream :: :ok | {:error, :wrong_expected_version} | {:error, error}`,
  `stream_forward :: Enumerable.t() | {:error, :stream_not_found}` [12].
- Dispatch:
  - `{:error, :unregistered_command}`, `{:error, :consistency_timeout}`, `{:error, :too_many_attempts}`;
  - `{:error, reason}` из `execute`;
  - `{:error, error, stacktrace}` при исключении [11].

**Telemetry.** Span-события [12][13]:

- `[:commanded, :application, :dispatch]`;
- `[:commanded, :aggregate, :execute | :populate]`;
- `[:commanded, :event_store, <функция>]`;
- `[:commanded, :event, :handle | :batch]`;
- `[:commanded, :process_manager, :handle]`.

OpenTelemetry — сторонний `opentelemetry_commanded` 0.2.1 (2026-05-12). Он требует `opentelemetry ~> 1.7`
(SDK) не optional [15].

**Совместимость.**

- `elixir: "~> 1.15"`; CI — Elixir 1.15–1.19 на OTP 26–28, без PostgreSQL [13].
- В 1.4.10 — «Fix Warnings for Elixir 1.19», 1.4.11 — документация и мелкие правки [13].
- Зависимости: `backoff`, `telemetry`, `telemetry_registry`; optional — `jason`, `phoenix_pubsub` [13].
- Адаптер — `elixir ~> 1.12`, зависит от `commanded ~> 1.4` и `eventstore ~> 1.4` [14].

## Maestro

- **Агрегат** — `use Maestro.Aggregate.Root, command_prefix:, event_prefix:, projections:`: GenServer на агрегат,
  `evaluate/2` = `GenServer.call` [17]. Обработчики команды и события ищутся по префиксу модуля и `type` [17].
  OTP-приложение `:maestro` поднимает `HLClock`, `Registry`, `Aggregate.Supervisor` [17].
- **Store.** Конфигурация `config :maestro, storage_adapter: Maestro.Store.Postgres, repo: MyApp.Repo` глобальна
  на VM и читается в рантайме [17]. `Store.commit_all(events, projections)` собирает `Ecto.Multi` из вставок и
  `project(repo, event)` и выполняет `repo.transact()`: проекции пишутся в транзакции событий [17].
- **Транзакция.** Корень вызывает `commit_all` в процессе агрегата [17], поэтому транзакция usecase не
  используется — вывод из кода. Прямой вызов публичного `Maestro.Store.commit_all/2` из usecase не проверялся.
- **Таблицы** создаёт mix-задача в repo потребителя [17]:
  - `event_log`: `timestamp` (HLC, binary PK), `aggregate_id` (binary), `sequence`, `type` (string 256), `body`
    (map); unique `aggregate_sequence_index`; колонок metadata, автора и correlation нет;
  - `snapshots` — upsert по `aggregate_id`.
- **Конфликт** — `{:error, :retry_command}`. Корень перечитывает агрегат и вычисляет команду заново; лимит
  попыток в коде не найден — вывод из кода [17].
- **Telemetry** нет. `elixir ~> 1.16`, CI — Elixir 1.17–1.18 и `postgres:9.6` [17].

## Ariadne Flow (`ariadne_flow`)

- **Модель DCB**: потоков и версии агрегата нет. Команда — event reducer; `dispatch/3` читает события по query
  (типы и теги), решает и пишет с append condition [18]. Конфликт после `:attempts` перерешений (по умолчанию 3) —
  `{:error, %Ariadne.Flow.AppendConditionError{}}` [18].
- **Store** создаётся в рантайме: `Ariadne.Flow.Store.Postgres.init(repo:, prefix:, context:)` [18].
  - Таблицы: `ariadne_flow_store` (`position`, `type`, `context`, `data` map, `tags`, `metadata` map,
    `created_at` usec), `…_tags`, `…_reactor_checkpoints`.
  - Миграция — вызов `Migration.up(prefix:)` из Ecto-миграции потребителя; версия схемы хранится комментарием
    на таблице.
- **Транзакция.** `Store.transaction/2` «joins an ambient one — … with the Postgres store, any transaction on the
  same repo» [18]. Append берёт `pg_advisory_xact_lock` по `(prefix, context)` [18]: все append в context идут по
  очереди до commit — вывод из кода. Реакторы выполняются после commit, их ошибки — `PostCommitError` [18].
- **Процессы.** В `mix.exs` нет `mod:`; `Application` — struct `%{store, reactors, scheduler}` [18]. Вывод:
  процессы библиотеке не нужны.
- **Тип и сериализация.** `@derive {Ariadne.Flow.Event, type: "course-defined"}`, по умолчанию — имя модуля.
  Свой encoder — `defimpl Ariadne.Flow.Event` с `encode/decode` [18].
- **Метаданные.** Опция dispatch `metadata:`; `created_at` — из опции или `DateTime.utc_now()`. Пользовательские
  ключи при чтении возвращаются строками [18].
- **Telemetry** — `[:ariadne, :flow, :dispatch]` и `[:ariadne, :flow, :store, :read | :append | :init_checkpoints]`
  [18]. `elixir ~> 1.18`, в devbox `postgresql@18.4`.
- **Сопровождение.** «Open source, not open contribution»; до 1.0 ломающее изменение поднимает minor [18].

**Spector и AshEvents** — не про агрегат:

- Spector пишет в таблицу событий changeset CRUD-операции (`payload`, `schema`, `action`, `parent_id`) и
  восстанавливает запись прогоном `changeset/2`. Операция идёт в одной транзакции; repo — опция
  `use Spector.Events, repo:` [19].
- AshEvents — расширение Ash: журнал событий является Ash-ресурсом, есть replay и транзакционные advisory locks.
  Зависимости — `ash ~> 3.33`, `ash_postgres ~> 2.0` [20][9].

## Соответствие критериям `:core`

| Критерий | EventStore | Commanded + адаптер | Maestro | Ariadne Flow |
|---|---|---|---|---|
| Транзакция с DAO (`Transact.run`) | частично: `conn:` из process dict Ecto для append/read/snapshot; store запущен; ошибка SQL роняет транзакцию; `$all` заблокирован до commit | нет: append в процессе агрегата | нет через агрегат (GenServer); `Store.commit_all` напрямую — не проверено | да: присоединяется к транзакции того же repo; advisory lock на context |
| Без процессов агрегата | да; supervisor store (пул, advisory-соединение, notifications) обязателен | нет: router → `open_aggregate`; `Commanded.Application` обязателен | нет: GenServer на агрегат, HLClock | да: процессов нет |
| Без конфигурации потребителя на компиляции | частично: литерал `otp_app` в `use`, конфиг — в рантайме; модуль store у потребителя, адаптеру — опцией | нет: `compile_config` снимает app env при компиляции; TypeProvider глобален | частично: `:maestro, repo:` в рантайме, но один на VM; префиксы — опции `use` | да: `init(repo:)` в рантайме |
| Optional-зависимость | частично: адаптер зовёт функции модуля из опции, структуры `EventData`/`RecordedEvent` — под `Code.ensure_loaded?` (вывод); OTP-приложение `:eventstore` стартует всегда | нет: `use`, `router`, behaviours — на компиляции | частично: `use …Root` на компиляции | частично: `@derive` в модулях событий |
| Свой wire-тег и сериализатор | да: `event_type` явно; `serializer` — behaviour (кодек-фасад можно обернуть — вывод) | частично: тег — через глобальный TypeProvider; сериализатор — у EventStore | частично: `type` задаёт выбор модуля обработчика; `body` — Ecto `:map` | да: `type:` в `@derive`, свой encoder |
| Метаданные автора и момента | да: `metadata`, `causation_id`/`correlation_id` (uuid), `created_at` из приложения или override | частично: `metadata:` и causation при dispatch; `created_at` задаёт EventStore | нет: колонки metadata нет | частично: `metadata:`, `created_at` из опции |
| Модель версии | `stream_version` назначает store от `expected_version` | то же, версию держит процесс | `sequence` + unique, `:retry_command` | DCB: позиция + append condition, версии агрегата нет |
| Telemetry | нет | да, OTel — сторонний пакет с SDK | нет | да |

## Развилки

1. **Своя реализация** на `Core.Es.Event.Repo.Pg`.
   - Уже есть: таблица событий на агрегат, unique `(aggregate_id, aggregate_version)`, запись через DAO в
     `Transact.run`, кодек-фасад.
   - Нет: свёртки, глобальной позиции, подписок, чекпоинтов, снапшотов, апкастеров (`map.md`, Notes).
   - Цена — реализовать механизмы из отчётов 01–04 и их тесты; telemetry и трейсы — через `Core.Otel`.
   - Конфликтов с принятыми решениями карты нет.

2. **EventStore + адаптеры `:core`.**
   - Даёт: `$all` без дыр (01), persistent-подписки с чекпоинтом и LISTEN/NOTIFY (02), таблицу снапшотов (04),
     soft/hard delete, версионированные миграции своей схемы.
   - Хранение: общие таблицы `streams/events/stream_events` на схему вместо таблицы у агрегата и
     `(aggregate_id, aggregate_version)`. Миграции — mix-задачи или `EventStore.Tasks.*`, отдельно от
     Ecto-миграций потребителя.
   - Транзакция: в `Transact.run` — только через `conn:` из process dict Ecto. Каждый store держит пул (10) и два
     отдельных соединения. Блокировка `$all` живёт всю транзакцию usecase, ошибка конфликта переводит её в aborted.
   - Версия: `stream_version` назначает store — расходится с «версию события поднимает домен, репозиторий только
     проверяет» (`map.md`, ADR-0001).
   - Чего нет: telemetry — spans и метрики пишет адаптер. Последний релиз — 2025-03, CI — до Elixir 1.17,
     зависимость `fsm` без релизов с 2018.
   - Модуль с `use EventStore, otp_app:` остаётся у потребителя — тот же случай, что
     `use Klife.Client, otp_app:` в `10-architecture.md`.

3. **Commanded + адаптеры.**
   - Конфликт с картой: путь команды — usecase → repo в `Transact.run` без процессов агрегата. Router, middleware
     и процессы агрегата вынесены в Out of scope.
   - Commanded выполняет команду только через router и процесс агрегата, append идёт вне транзакции usecase.
     `Commanded.Application` обязателен для `Commanded.EventStore`, обработчиков событий и снапшотов.
   - Без процессов остаются модули:
     - behaviour `execute/apply` — decide/evolve с другим порядком аргументов (04);
     - протокол `Upcaster` (03);
     - `Aggregate.Multi`;
     - TypeProvider/`JsonDecoder` (вывод из кода).
   - Из варианта 2 добавляется всё, включая ограничения.
   - Конфиг приложения снимается при компиляции, TypeProvider глобален.
   - OTel-интеграция тянет SDK `opentelemetry`, а `21-observability.md` отдаёт SDK потребителю.

4. **Maestro / Ariadne Flow.**
   - Maestro: GenServer на агрегат и нет колонки метаданных — конфликт с путём команды и с метаданными автора.
     Repo и storage adapter глобальны на VM.
   - Ariadne Flow: единственный кандидат с транзакцией на repo потребителя и без процессов. Но это DCB без версии
     агрегата — конфликт с Destination («проверка ожидаемой версии») и unique `(aggregate_id, aggregate_version)`.
     На hex один релиз, PR не принимаются.

## Не найдено

- **Elixir 1.20** не подтверждён ни у одного кандидата:
  - CI: EventStore — до 1.17, Commanded — до 1.19, Maestro — до 1.18, у Flow матрица CI не найдена;
  - поиск по issues commanded/commanded и commanded/eventstore упоминаний 1.20 не дал;
  - чужой код не собирался.
- **EventStore:** в документации нет поведения `conn:` при ошибке внутри внешней транзакции и цены блокировки
  `$all` на длинных транзакциях — это выводы из кода. Способ не запускать notifications и advisory locks не найден.
  Сравнение с форком `straw-hat-team/eventstore` (push 2026-09-02) не получено: compare API ответил 404.
- **Commanded:** документированного способа выполнить команду без процесса агрегата нет.
- **Maestro:** вызов `Store.commit_all` внутри транзакции потребителя не проверен; требований к PostgreSQL в README
  нет.
- **Ariadne Flow:** минимальная версия PostgreSQL не указана; как advisory lock ведёт себя в присоединённой внешней
  транзакции, сверх «joins» не описано.
- **Spector, AshEvents** детально не изучались.

## Источники

1. commanded/eventstore `v1.4.8`, `lib/event_store.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store.ex ; https://hexdocs.pm/eventstore/EventStore.html
2. там же, `lib/event_store/supervisor.ex`, `application.ex`, `config.ex`, `config/store.ex`, `notifications/supervisor.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/supervisor.ex
3. там же, `lib/event_store/streams/stream.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/streams/stream.ex
4. там же, `lib/event_store/storage/appender.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/storage/appender.ex
5. там же, `serializer.ex`, `json_serializer.ex`, `jsonb_serializer.ex`, `event_data.ex`, `recorded_event.ex`, `guides/Event Serialization.md` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/serializer.ex
6. там же, `guides/Getting Started.md`, `guides/Upgrades.md`, `lib/mix/event_store.ex`, `lib/event_store/tasks/migrate.ex`, `lib/event_store/sql/init.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/guides/Upgrades.md
7. там же, `mix.exs`, `README.md`, `.github/workflows/test.yml` — https://github.com/commanded/eventstore/blob/v1.4.8/mix.exs
8. commanded/eventstore: сравнение `v1.4.8...master`, `CHANGELOG.md`, issues #163, #309, PR #319 — https://github.com/commanded/eventstore/compare/v1.4.8...master ; https://github.com/commanded/eventstore/issues/163
9. hex.pm API: `eventstore`, `commanded`, `commanded_eventstore_adapter`, `maestro`, `ariadne_flow`, `spector`, `ash_events`, `fsm` — https://hex.pm/api/packages/eventstore
10. commanded/commanded `v1.4.11`, `lib/application.ex`, `lib/commanded/application/supervisor.ex`, `application/config.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/application/supervisor.ex
11. там же, `lib/commanded/commands/dispatcher.ex`, `aggregates/aggregate.ex`, `aggregates/execution_context.ex`, `aggregates/multi.ex`, `commands/router.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/commands/dispatcher.ex
12. там же, `lib/commanded/event_store.ex`, `event_store/adapter.ex`, `event/mapper.ex`, `event_store/type_provider.ex`, `serialization/module_name_type_provider.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/event_store.ex
13. там же, `mix.exs`, `.github/workflows/test.yml`, `guides/Application.md`, `lib/commanded/telemetry.ex`; `CHANGELOG.md` @ `936dbb1` — https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/CHANGELOG.md
14. commanded/commanded-eventstore-adapter `v.1.4.2`, `lib/commanded/event_store/adapters/event_store.ex`, `mapper.ex`, `mix.exs` — https://github.com/commanded/commanded-eventstore-adapter/blob/v.1.4.2/lib/commanded/event_store/adapters/event_store.ex
15. `opentelemetry_commanded` 0.2.1 — https://hex.pm/packages/opentelemetry_commanded
16. PostgreSQL 18, NOTIFY — https://www.postgresql.org/docs/current/sql-notify.html
17. elixir-toniq/maestro `ed860f3`: `README.md`, `lib/maestro/store/postgres.ex`, `store.ex`, `aggregate/root.ex`, `types/event.ex`, `application.ex`, `lib/mix/tasks/maestro.create.event_store_migration.ex`, `.github/workflows/ci.yml` — https://github.com/elixir-toniq/maestro/blob/ed860f3/lib/maestro/store/postgres.ex
18. modell-aachen/flow `ba17a65`: `README.md`, `docs/store.md`, `docs/application.md`, `docs/encoder.md`, `lib/flow/store/postgres.ex`, `lib/flow/store.ex`, `lib/flow/application.ex`, `mix.exs` — https://github.com/modell-aachen/flow/blob/ba17a65/docs/store.md
19. ityonemo/spector `43c7629`: `README.md`, `lib/spector/migration.ex` — https://github.com/ityonemo/spector
20. ash-project/ash_events `56e30e8`, `README.md` — https://github.com/ash-project/ash_events
21. Поиск кандидатов: hex.pm API (`/api/packages?search=…`), GitHub search; `sourced` 0.2.0 (tarball hex, `README.md`), MontiniSoftware/orkestra `082da18` (`lib/orkestra/event_store/`) — https://hex.pm/api/packages?search=event+sourcing ; https://gitlab.com/dimakula/sourced ; https://github.com/MontiniSoftware/orkestra
