# События и Outbox

Плейсхолдеры: `<Aggregate>` — см. `10-architecture.md`.

## Domain events

Событие агрегата: `use Es.Event` (см. `11-domain.md`) + вложенный `Payload` (или `nil`).

Объединяющий модуль (`<Aggregate>.Event`):

| Функция | Назначение |
|---|---|
| `name/1` | wire-type через `<Aggregate>.Event.Codec` |
| `names/0` | множество wire-type через Codec |

Dump/load — только через фасад: `InCodec`/`OutCodec.dump(event)` отдаёт **весь конверт**, `InCodec.load(<Aggregate>.Event, data)` восстанавливает событие по тегу внутри конверта (модуль событий агрегата — это семейство, `union:` у плагина; `codec.load(Mod, data)` — когда конкретный тип известен). Неизвестный тег → `:unknown_event_type` кодека агрегата (`ns: :es`). Момент постановки в outbox: `Outbox.CreatedAt.now()` (usec); `event.at` — только в конверте (`"at"`), не в `Record.created_at`.

Правила:

- Агрегат при мутациях **копит** `events` в struct; сам не пишет в event store и outbox.
- Flush — задача Repo, **в одной DB-транзакции** со state.
- Flush руками не пишется: его генерирует `use Core.Repo.Pg.Es` по опциям `event_repo:` и
  `outbox:` (см. `13-repos.md`). Порядок внутри транзакции:
  `Outbox.from_events` → `Event.Repo.append` → `Outbox.Repo.append`, затем `events` очищаются.
- Кодек событий агрегата — `use Core.Es.Event.Codec` (`event:` + `tags:`, плюс колбэки
  `dump_payload/2` и `load_payload/3`); конверт, выбор типа по тегу и сборку события
  генерирует билдер, наружу кодек виден только через фасад. `load_payload/3` возвращает
  `%Payload{}`, а не событие; событиям без нагрузки клоузы не нужны вовсе.
- Prim агрегата и автора билдер выводит из самих событий (`__es_aggregate_id__/0`,
  `__es_by__/0`) — опциями они не задаются, расхождение между событиями одного кодека
  ловится на компиляции.
- Wire-тег уникален **внутри своего кодека** (дубль — `CompileError`), но квалифицировать
  его именем агрегата (`acceptance.created`, а не `created`) MUST: тег виден в брокере и в
  event store рядом с чужими. Кодек событий MUST быть в `Codec.plugins()` — иначе фасад не
  знает ни события, ни его семейства.

Конкурентная запись ловится unique-индексом `(aggregate_id, aggregate_version)` в таблице событий:
`Event.Repo.append/2` отдаёт доменный `:version_mismatch` из `<Aggregate>.Errors`. На строке агрегата
`optimistic_lock` не используется — `version` проверяется на чтении, а расходится он именно здесь.

## Aggregate → Outbox.Record

Модуль `<Aggregate>.Outbox` целиком генерируется — руками только `@moduledoc` и две опции:

```elixir
use Es.Outbox,
  topic: "<topic>",
  event: Agg.Event
```

`topic` валидируется `Outbox.Topic` на этапе компиляции: опечатка — `CompileError`, а не ошибка
в рантайме на каждом событии.

API:

- `from_event/1` → `{:ok, Record.t()} | {:error, Error.t()}`
- `from_events/1` → `{:ok, [Record.t()]} | {:error, Error.t()}`

Поля Record: topic / key (= aggregate id) / name (= event name) / payload (JSON-объект) / headers (MQ-заголовки | `nil`) / lifecycle-поля (`status`, `attempts`, `locked_until`, `lease_id`, …).

`payload` — **только map**: колонка `payload` имеет тип `:map`, и list / binary / скаляр не дампятся (падение на записи). Нужен не-JSON body — это отдельная колонка и отдельное решение, а не расширение типа.

`Delivery.Mq`: body = `Jason.encode(payload)`. Headers — `Record.headers` как есть (`nil` → без заголовков); delivery MUST NOT достраивать заголовки из `name` / `key` / payload.

Заголовки задаёт продюсер записи. Для событий агрегата — `<Aggregate>.Outbox.from_event/1`: `name` (= event name), `aggr_id` (= aggregate id), `event_id`.

Wire-payload — конверт события целиком:

- `event_id`, `type`, `aggregate_id`, `aggregate_version`, `at`, `by`
- плюс payload события (`payload`; у событий без нагрузки — `nil`)

Обе стороны формата — в `Core.Es.Event.Codec`: конверт собирает `dump/2` кодека агрегата
(его зовёт `<Aggregate>.Outbox` при постановке события в очередь), разбирает — `load/3`,
до которого подписчика доводит фасад по тегу. Разносить стороны формата по разным модулям
MUST NOT: переименованный ключ обнаружится не тестом, а подписчиком в проде. Транспорту,
который хранит поля врозь (event store — по колонкам), их отдаёт пара `to_fields/1` /
`from_fields/1`: строковые ключи конверта не покидают кодека.

Разбор **safe**: событие с типом, которого кодек больше не знает, становится доменной
ошибкой у подписчика (`:unknown_event_type`), а отсутствующее обязательное поле конверта —
`:invalid_envelope` (обе — `ns: :es`); сообщение из брокера переживает код, который его
писал, и уронить подписчика не вправе.

## Совместимость событий

Строки в event store живут вечно и читаются текущим кодом. Единственный источник wire-имён —
`@tag_by_mod` в `<Aggregate>.Event.Codec`; формат payload задаёт `dump_payload/2`.
Оттуда же его берут запись outbox и её заголовки (`Core.Es.Event.Codec.to_fields/1`).
Любое несовместимое изменение обнаружится не в тесте, а на проде — при чтении истории.

| Изменение | Статус |
|---|---|
| новое событие (новый тег) | разрешено |
| новое **опциональное** поле payload | разрешено; `load_payload` обязан читать payload без него |
| переименование wire-тега | **запрещено** |
| переименование поля payload | **запрещено** |
| удаление поля payload | **запрещено** (перестать писать — можно, читать — обязаны) |
| удаление типа события | тег и clause `load_payload` остаются навсегда |
| смена типа значения поля | только через новое поле + upcast по `aggregate_version` |

### Golden-фикстуры

`test/support/fixtures/events/<aggregate>/<wire_tag>.json` — снимок дампа каждого события.
Файлы **не перегенерируются**: это то, что уже лежит в проде.

Тест на агрегат (`use MyApp.EventCompatCase`) проверяет два инварианта:

1. у каждого тега из `Event.Codec.types/0` есть фикстура — новый тип не добавить,
   не зафиксировав формат;
2. каждая фикстура грузится через `InCodec.load(<Aggregate>.Event, _)` — переименование тега или поля,
   удаление поля и смена типа значения ломают тест.

Добавили событие — добавьте фикстуру (дамп реального события, не выдуманный JSON).
Понадобилось несовместимое изменение — это новый тип события, а не правка старого.

## Outbox lifecycle

Статусы: `:new → :in_work → :published | :failed`.

| Компонент | Назначение |
|---|---|
| `Poller` | reserve (под токеном аренды `lease_id`) → `publish_many` → save_results; один sequential publisher; drain после `:processed`; idle/error — adaptive backoff; `wake/1` (имя обязательно) после commit `append` (coalesce `:wake` в mailbox) |
| `Delivery.Mq` | JSON body + `Record.headers` как есть; `publish_many` → `Writer.put_many` (stop-on-first-error). Единственный Delivery: брокер подключается адаптером `Mq.Writer` (`Mq.Stream.Writer`, `Mq.Kafka.Writer`), не отдельным `Delivery.*` |
| `Cleaner` | TTL published |
| `Outbox.Supervisor` | OTP-сборщик; `enabled: true` в dev/prod, `false` в test |

Ключ конфига — `Core.Outbox` (Core-namespace, не app-модуль `MyApp.Outbox`): Core (`Outbox.Repo.Pg`) и app-обвязка (`Outbox.Supervisor`) читают один ключ.

Tunables (`enabled`, `batch_size`, `poll_interval_ms`, `idle_min_ms`, …) — **только** `config/runtime.exs` + env `OUTBOX_*` (SSOT). MUST NOT дублировать в `config.exs`. В `:test` — overlay в `config/test.exs` (runtime-блок Outbox пропускается).

| Env | Назначение |
|---|---|
| `OUTBOX_ENABLED` | Supervisor (Writer + Poller + Cleaner) |
| `OUTBOX_POLL_INTERVAL` | max idle / safety poll (cap backoff) |
| `OUTBOX_IDLE_MIN` | стартовый idle backoff; drain → `schedule(0)` |
| `OUTBOX_BATCH_SIZE` | размер пачки reserve |
| `OUTBOX_LOCK_DURATION` | аренда `:in_work` |
| `OUTBOX_MAX_ATTEMPTS` | порог `:failed` |
| `OUTBOX_PUBLISHED_TTL` | TTL для Cleaner |
| `OUTBOX_CLEANER_INTERVAL` | интервал Cleaner |
| `OUTBOX_REFERENCE_PREFIX` | producer reference для `Stream.Writer` |
| `OUTBOX_ALLOW_CLUSTER` | разрешить старт при `DNS_CLUSTER_QUERY` (ценой порядка доставки) |

Длительности (`OUTBOX_POLL_INTERVAL`, `OUTBOX_IDLE_MIN`, `OUTBOX_LOCK_DURATION`, `OUTBOX_PUBLISHED_TTL`, `OUTBOX_CLEANER_INTERVAL`) задаются строкой вида `"1s"` / `"50ms"` / `"1h30m"` / `"7d"` и разбираются `Core.DurationParser.parse!/2` в единицу ключа конфига (`*_ms` / `*_seconds`). Голое число без единицы и неточная конвертация (`"1500ms"` → секунды) — ошибка старта, а не тихое усечение.

Дополнительно в config Outbox: `poller_name` (atom имени GenServer; в test — `nil`, wake no-op) и `pollers` (`[[name:, topics:], …]` — таргеты `Poller.wake/1` после commit `append`).

### Poller scheduling

- После `:processed` — немедленный следующий цикл (`schedule(0)`, drain очереди).
- После `:idle` / ошибки цикла — backoff: `idle_min_ms`, ×2, …, cap = `poll_interval_ms`.
- Если во время цикла пришли `:wake` и результат `:idle` / error — `schedule(0)` (не полный backoff).
- Входящие `:wake` coalesce'ятся (`flush_wakes` в начале/конце цикла) — mailbox не растёт пропорционально RPS `append`.
- `Outbox.Repo.append` регистрирует `Poller.wake/0` через `Helper.AfterCommit` (после outermost commit; вне TX — сразу). Same-VM only; другие ноды — safety poll.
- `DAO` объявляется через `use Core.DAO`: `transact` / `transaction` обёрнуты в `AfterCommit.wrap` (depth / rollback-safe).

### Порядок доставки

- Один Poller + один `Stream.Writer`; concurrency > 1 запрещён (порядок в stream).
- Порядок publish = `order_by: created_at` при `fetch_and_reserve`.
- Ошибка на index `i` в батче — fail-stop: `0..i-1` published, `i` failure/retry, `i+1..` → `Record.release` (`:new`, без инкремента attempts).
- `Mq.Writer.put_many/2` / `Delivery.publish_many/2` — sequential publish в одном call.

`Outbox.Repo` API: `append`, `fetch_and_reserve`, `save_results`, `release`, `delete_published_before` (возвращает `non_neg_integer()` — число удалённых), `requeue_failed`, статистика для метрик (`counts_by_status`, `oldest_age_seconds`, `expired_lock_count`).

**Fencing аренды.** `fetch_and_reserve` выдаёт пачке общий `lease_id` и пишет его в строку;
`save_results` / `release` обновляют строки `UPDATE ... WHERE id IN (...) AND lease_id = ?`.
Перехваченная после истечения аренды запись и удалённая `Cleaner` строка не обновляются и
не воскресают (upsert здесь запрещён) — расхождение уходит в `warning`.

**Порядок внутри пачки** — `order_by: [created_at, id]`: `created_at` ставится на каждое
событие отдельно и может совпасть в микросекунде, `id` (UUIDv7) даёт tiebreaker. Часть ошибок — `Error.app` + `raise Exc`. Persist `Record` в Schema — через `Outbox.Codec` / `InCodec.load`/`dump` (remap JSON errors string↔atom keys). `persist_all!` / `append` чанкуют `insert_all` (лимит параметров PostgreSQL при больших batch).

### Единственность поллера

Гарантия порядка держится на одном поллере на топик-группу. `FOR UPDATE SKIP LOCKED` защищает
от дублей, но не от перестановки: две ноды разложат одну очередь в брокер вперемешку.

- MUST: `OUTBOX_ENABLED=true` ровно на одном инстансе.
- Кластеризация (`DNS_CLUSTER_QUERY` задан) вместе с включённым outbox — **отказ старта**
  (`Outbox.Supervisor.check_singleton!/0`, `ArgumentError` с инструкцией).
- `OUTBOX_ALLOW_CLUSTER=true` — осознанный отказ от гарантии порядка: старт разрешён,
  в лог уходит `warning`. Ставить только там, где порядок не важен.
- Переход на несколько нод без потери порядка требует лидер-элекции (`:global` /
  advisory-lock на топик-группу) — отдельная задача, не покрыта.

### Runbook: записи в `:failed`

Алерты Prometheus на стороне приложения: `OutboxQueueFailedGrowing`
(`outbox_queue_count{status="failed"} > 0`), `OutboxFailedDelivery`, `OutboxOldestNewHigh`.

`Cleaner` удаляет только `published` — `:failed` копятся, пока их не разберёт оператор:

1. Причина — колонка `errors` таблицы `outbox` (список `{attempt, message}`) и логи
   `"Outbox окончательно провален: id=..."`.
2. Починить источник отказа (брокер, топик, права, формат payload).
3. Вернуть в очередь: `mix outbox.requeue --all` или `mix outbox.requeue --id <uuid>`
   (`Outbox.Repo.requeue_failed/2`: `:failed` → `:new`, `attempts` = 0, аренда снята).

Порядок доставки для возвращённых записей **не восстанавливается**: сообщения, шедшие за ними,
уже опубликованы. Если порядок критичен — вместе с requeue нужен пересчёт состояния получателем.

## Идемпотентность потребителей

Доставка — **at-least-once** на каждом звене: outbox переотправляет батч после сбоя,
брокер передоставляет неподтверждённое, Oban повторяет джобу до `max_attempts`.
Значит, обработчик обязан переживать повтор.

- Воркер с **внешним** эффектом (HTTP клиенту, отправка сообщения, списание) MUST иметь
  `unique:` с ключом, однозначно определяющим событие:

  ```elixir
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:message_id, :status, :event_id]]
  ```

  `event_id` в ключе обязателен: `message_id + status` повторяются при переоткате статуса,
  а `event_id` уникален для конкретного факта.
- Джоба-**команда** (не реакция на событие) события не имеет — ключ строится из набора
  идентификаторов агрегатов, а `period` конечен: повторная отправка тех же сообщений
  позже законна, вечная уникальность её заблокировала бы.

  ```elixir
  # Workers.SendMessage — args либо %{"message_ids" => [...]}, либо %{"message_id" => id}
  unique: [period: 60, states: :incomplete, keys: [:message_ids, :message_id]]
  ```

  `unique` защищает от дублирующего **enqueue** (два прогона `DrainPending`), а не от
  повторного выполнения ретрая: от него защищает переход статуса агрегата под
  optimistic lock event store'а.
- Воркер, который только меняет состояние в БД, идемпотентен, если мутация агрегата
  проверяет текущий статус и возвращает `{:error, _}` / no-op на повторе.
- Обработчик MQ-сообщения MUST быть готов к дублю и к **перестановке** относительно других
  топиков; порядок гарантирован только внутри одной топик-группы.
- «Ядовитое» сообщение (обработчик стабильно возвращает ошибку) MUST иметь выход:
  `MqSubscriberReliable` считает попытки, растит интервал до `retry_max_ms` и после
  `max_attempts` публикует сырое сообщение в DLQ-топик (`<topic>.dlq`, заголовки
  `x-dlq-source-topic` / `x-dlq-attempts` / `x-dlq-error`), коммитит offset и эмитит
  `[:mq, :subscriber, :dlq]` (алерт `MqSubscriberDlq`). Без настроенного `dlq_writer`
  сообщение не выбрасывается — повторы продолжаются, в лог идёт `error`.
- Поэтому дерево подписчика MUST поднимать **свой** `Mq.Stream.Writer` и передавать его
  каждому `MqSubscriberReliable` (`dlq_writer` + `dlq_handle`). Свой, а не writer outbox:
  тот выключается вместе с outbox (`OUTBOX_ENABLED=false`), а выход для «ядовитого»
  сообщения обязан работать независимо от публикации событий. `reference_prefix` у него
  отдельный — общий с outbox пересёк бы счётчики подтверждений по одноимённым топикам.
  Writer идёт **первым** ребёнком при `:rest_for_one`.

### Runbook: сообщения в DLQ

1. Алерт `MqSubscriberDlq` → топик и `dlq_topic` в метках.
2. Причина — в логе подписчика (`сообщение отправлено в DLQ после N попыток`) и в заголовке
   `x-dlq-error` самого сообщения.
3. Починить обработчик, затем переиграть содержимое DLQ-стрима в исходный топик
   (порядок относительно уже обработанных сообщений не восстанавливается).
- Инвалидация кеша по событию — только `del` по id, без обновления из payload
  (`16-caching.md` свода приложения): payload может прийти устаревшим.

## Связанные правила

- Es.Event / агрегаты / `Event.Codec` — `11-domain.md`
- OTP-процессы поллеров и читателей — `17-otp-concurrency.md`
- Flush в Repo (`Repo.Pg.Es`), event store (`Es.Event.Repo`) — `13-repos.md`
- Кеш ReadRepo (инвалидация по событиям) — `16-caching.md` свода приложения
- Архитектура слоёв — `10-architecture.md`
