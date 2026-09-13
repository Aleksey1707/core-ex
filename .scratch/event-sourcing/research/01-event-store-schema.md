# Схема event store на PostgreSQL и глобальный порядок

Исследование на 2026-09-13. Версии: Commanded EventStore `v1.4.8`, Commanded `v1.4.11`, Marten `V9.33.0`,
Emmett `0.42.4`, Message DB `v1.3.0`.

## Вопрос

Тикет: [Готовые решения: схема event store на PostgreSQL и глобальный порядок](../issues/01-research-event-store-schema.md).

Как четыре решения хранят события, назначают глобальную позицию, не дают читателю по позиции пропустить
событие конкурентной транзакции (и сколько это стоит на запись), проверяют ожидаемую версию потока,
хранят время и метаданные, удаляют и архивируют потоки.

## Commanded EventStore (Elixir)

**Таблицы** [1]. Схема общая для всех потоков:

- `streams`: `stream_id bigserial PK`, `stream_uuid text` (unique `ix_streams_stream_uuid`), `stream_version bigint`,
  `created_at timestamptz`, `deleted_at timestamptz`. Строка `stream_id = 0, stream_uuid = '$all'` создаётся при
  инициализации.
- `events`: `event_id uuid PK`, `event_type text`, `causation_id uuid`, `correlation_id uuid`, `data` и `metadata`
  (тип задаёт `column_data_type`, bytea или jsonb), `created_at timestamptz DEFAULT NOW()`.
- `stream_events`: связь события с потоком — `event_id` (FK), `stream_id` (FK), `stream_version`,
  `original_stream_id`, `original_stream_version`; PK `(event_id, stream_id)`, unique `ix_stream_events (stream_id, stream_version)`.
- Ещё `subscriptions` (`last_seen`), `snapshots`, `schema_migrations`.
- Триггеры запрещают `UPDATE` таблиц `events` и `stream_events`, а `DELETE` — пока не включён hard delete [1].
- Триггер `AFTER INSERT OR UPDATE ON streams` шлёт `pg_notify` с диапазоном версий [1][7].

**Глобальная позиция** — это `stream_version` события в потоке `$all`. Один SQL-оператор (CTE) делает всё сразу
[2]: вставляет `events`, увеличивает `streams.stream_version` своего потока, выполняет
`UPDATE streams SET stream_version = stream_version + $n WHERE stream_id = 0 RETURNING stream_version - $n`
и пишет в `stream_events` строки для своего потока и для `$all` с номерами `initial + index`.
`read_all_streams_forward` — это `read_stream_forward("$all")` [5]: `WHERE se.stream_id = 0 AND se.stream_version >= $2`.

**Защита от пропуска.** Sequence нет — счётчик лежит в строке таблицы. `UPDATE` строки `$all` берёт row lock до конца
транзакции, поэтому конкурентные append ждут друг друга. Номера выдаются в порядке коммитов, без пропусков:
откат возвращает и счётчик. Это вывод из кода [2] и семантики row lock в PostgreSQL — документация проекта
механизм не описывает. **Цена на запись:** все append в одной схеме сериализуются на одной строке `$all`
на время всей транзакции, включая append внутри внешней транзакции через `conn:` [5]. Больше 1000 событий
пишутся пачками по 1000 в одной транзакции (лимит параметров Postgres) [3].

**Ожидаемая версия** [4]. Сначала `stream_info` читает поток, потом на Elixir выполняется
`validate_expected_version`. Значения: `:any_version | :no_stream | :stream_exists | integer`. Ошибки:
`:wrong_expected_version`, `:stream_exists`, `:stream_not_found`, `:stream_deleted`. Гонку между чтением и записью
ловит unique-индекс: `unique_violation` на `ix_stream_events` → `{:error, :wrong_expected_version}`,
на `ix_streams_stream_uuid` → `:duplicate_stream_uuid` с одним повтором (`maybe_retry_once`) [3][4].
На `:wrong_expected_version` Commanded дочитывает недостающие события в агрегат и повторяет команду, если
в `ExecutionContext` остались попытки [11].

**Время и метаданные.** `created_at` — `timestamptz`; значение задаёт приложение: `DateTime.utc_now()` или
`created_at_override` [4][8]. `correlation_id` и `causation_id` — отдельные колонки `uuid`, остальное —
в `metadata` [1][8]. Commanded кладёт в `causation_id` UUID команды [11]. В master после `v1.4.8` коммит
`4a88a29` добавил настройку типа колонок correlation/causation; в тег он не вошёл [10].

**Удаление** [6][9]. Soft: `UPDATE streams SET deleted_at = NOW()` — поток нельзя читать и дописывать, но его события
остаются в `$all`. Hard: CTE удаляет `stream_events` (вместе со ссылками), `events` и `streams`. По умолчанию выключен
(`enable_hard_deletes`), без флага триггер бросает `feature_not_supported` → `{:error, :not_supported}`. События
пропадают и из `$all`: в его нумерации появляются дыры — вывод из SQL [9]. Архивации нет.

## Marten (.NET)

**Таблицы** [12][24]:

- `mt_events`: `seq_id` (PK), `id uuid`, `stream_id` (FK → `mt_streams`, `ON DELETE CASCADE` без conjoined tenancy),
  `version`, `data jsonb`, `bdata bytea`, `type`, `timestamp timestamptz DEFAULT now()`, `tenant_id`, `mt_dotnet_type`, `is_archived`.
  Колонки `correlation_id`, `causation_id`, `headers`, `user_name` — только по opt-in; ещё опционально `is_skipped` и `tags`.
- Индексы: unique `pk_mt_events_stream_and_version (stream_id, version[, is_archived | tenant_id])`,
  опционально unique `(id)` и `(type, seq_id)`.
- `mt_streams`: `id` (uuid или varchar), `type`, `version`, `timestamp`, `created`, `tenant_id`,
  `compacted_version`, `is_archived`.
- Служебные: `mt_event_progression`, `mt_high_water_skips` [16][24].
- Опции: партиционирование по `is_archived` (hot/cold) или по `tenant_id` со своей sequence на тенанта [12][13].

**Глобальная позиция** — `seq_id = nextval('mt_events_sequence')` [13][15]. Sequence нетранзакционна: номер
выдаётся до коммита, откат сжигает его навсегда [17].

**Защита от пропуска: high-water mark на стороне читателя.** Запись ничем не блокируется. Async daemon двигает
границу, ниже которой все события закоммичены, только по сплошному префиксу `seq_id` [17]:

- `GapDetector` одним оператором (один снапшот) ищет первую дыру через `lead(seq_id) over (order by seq_id)`
  от текущей отметки, иначе берёт `max(seq_id)`; ведущую дыру над отметкой держит [16].
- С 9.23 дыра считается мёртвой, только когда не осталось транзакций, которые могли её зарезервировать.
  `GapLivenessProbe` проверяет `pg_stat_activity` (`xact_start <= first_observed`, блокировки на `mt_events`)
  и `pg_snapshot_xip(pg_current_snapshot())` [16]. Мёртвый диапазон пропускается одним шагом и записывается
  в `mt_high_water_skips` [16][17].
- Опциональный `SkipStaleGapsDespiteLiveTransactionsAfter` (по умолчанию null) пропускает дыру «по подозрению».
  Документация предупреждает: событие, закоммиченное внутри пропущенного диапазона, никогда не будет спроецировано.
  Ручной обход — `AdvanceHighWaterMarkToLatestAsync()` [17].
- Дыры от упавших транзакций: Rich-режим вставляет строки-«tombstone» с их `seq_id` [18]. Quick-режим
  (с Marten 9 по умолчанию `QuickWithServerTimestamps`) проверяет версию до `nextval`, чтобы проигравший OCC
  не сжигал номер (#4765) [13]. `StaleSequenceThreshold` по умолчанию 3 с; «пропуск» событий в Rich-режиме
  под нагрузкой документирован [19].

**Цена:** на запись — только `nextval`. Цена у читателя: задержка до закрытия дыр, остановка на долгих транзакциях
и `idle in transaction` [17], периодический запрос к `mt_events` с оконной функцией и сложный детектор.

**Ожидаемая версия.** Quick-путь: функция `mt_quick_append_events(..., expected_version DEFAULT NULL)` читает
`mt_streams.version`; при `UseExclusiveLockOnConcurrentAppends` — с `FOR UPDATE`. При несовпадении бросает
`RAISE ... ERRCODE 'MT003'`, в .NET это `EventStreamUnexpectedMaxEventIdException`. Дописывание в архивный поток
даёт `MT001` → `InvalidStreamOperationException` [13][14]. Последний рубеж — unique `(stream_id, version)` [12].
API: `FetchForWriting` бросает `ConcurrencyException`; `FetchForExclusiveWriting` берёт row lock и при таймауте бросает
`StreamLockedException` [20]; `AppendExclusive` держит блокировку потока до `SaveChangesAsync`;
`StartStream` на существующий поток бросает `ExistingStreamIdCollisionException` [18].

**Время и метаданные.** `timestamp` — `timestamptz` [21]. Quick пишет `now() at time zone 'utc'`,
`QuickWithServerTimestamps` — время из `TimeProvider` приложения или явно заданное в `IEvent` [13][23].
Correlation и causation берутся из сессии, а по умолчанию — из активного span OpenTelemetry [23].

**Удаление и архивация.** `ArchiveStream` через функцию `mt_archive_stream` ставит `is_archived = TRUE` потоку и его
событиям; с партиционированием строки переезжают в архивную партицию. Daemon и LINQ архивные события по умолчанию
пропускают [21]. Compaction (с 8.0, `CompactStreamAsync`) сворачивает события до версии или времени в снапшот
`Compacted<T>` и удаляет их; перед удалением вызывается хук архиватора [22].

## Emmett (TypeScript, PostgreSQL)

**Таблицы** [25]. Обе партиционированы `LIST (partition)`, а внутри — по `is_archived` (`_active` / `_archived`):

- `emt_streams`: `stream_id text`, `stream_position bigint`, `partition`, `stream_type`, `stream_metadata jsonb`,
  `is_archived`; PK `(stream_id, partition, is_archived)`.
- `emt_messages`: `stream_position`, `global_position bigint DEFAULT nextval('emt_global_message_position')`,
  `transaction_id xid8 NOT NULL`, `created timestamptz DEFAULT now()`, `is_archived`, `message_kind` (`E`/`C`),
  `stream_id`, `partition`, `message_schema_version`, `message_id text`, `message_type`, `message_data jsonb`,
  `message_metadata jsonb`; PK `(stream_id, stream_position, partition, is_archived)`.
  Unique на `global_position` в DDL нет.
- Миграция 0.42.4 добавляет индексы `(global_position)` и `(transaction_id, global_position)` под опрос
  потребителей; её создание берёт ShareLock и блокирует запись [28].
- `emt_processors` хранит чекпоинт (`last_processed_checkpoint text`, `last_processed_transaction_id xid8`) [25][27].
- Страница документации всё ещё называет таблицу `emt_subscriptions`, которую миграция 0.43.0 удаляет [31][25].

**Глобальная позиция.** Sequence плюс `transaction_id = pg_current_xact_id()` в каждой строке [26].

**Защита от пропуска: xid + снапшот.** Читатель берёт только строки транзакций старше самой старой активной
[27]: `WHERE transaction_id < pg_snapshot_xmin(pg_current_snapshot()) ... ORDER BY transaction_id, global_position LIMIT n`.
Все такие транзакции уже завершены, а любая будущая строка получит `xid >= xmin`, то есть окажется после
прочитанного, если курсор — пара `(xid, position)`. Статья автора Emmett описывает тот же приём [32]
(`bigserial` выдаёт номер до коммита, фильтр по `pg_snapshot_xmin`).

- В `0.42.4` курсор `after` сравнивается только с `global_position >= from`, хотя сортировка идёт по
  `(transaction_id, global_position)` [27].
- В master (`d1882f6`) курсор переписан на `(transaction_id, global_position) > (...)`, чекпоинт хранится как
  `txid:globalpos` [30][27]. Причину миграция описывает только как смену формы курсора [28].

**Цена:** на запись — xid8-колонка и составной индекс, без блокировок. У читателя события задерживаются до конца
самой долгой транзакции, удерживающей xmin; статья называет это компромиссом и противопоставляет «nuke option» —
блокировку строки-синглтона, сериализующую запись [32].

**Ожидаемая версия** [26][29]. SQL-функция `emt_append_to_stream`:

- `expected = NULL` — берёт текущую позицию, проверки нет;
- `0` — `INSERT` в `emt_streams`; конкурентное создание даёт `23505`;
- иначе — `UPDATE emt_streams SET stream_position = next WHERE ... AND stream_position = expected`; 0 строк → `success = false`.

Оба исхода превращаются в `ExpectedVersionConflictError(-1n, expected)` с `TODO: Return actual version` [29].
`STREAM_EXISTS` и `STREAM_DOES_NOT_EXIST` отображаются в NULL с `TODO: this needs to be fixed` — в PostgreSQL-append
на этом теге они не проверяются [26]. `handleCommand` повторяет команду при `isExpectedVersionConflictError` [29].

**Время и метаданные.** `created timestamptz DEFAULT now()` [25]. Метаданные — `message_metadata jsonb` [26];
отдельных полей correlation/causation в коде не найдено.

**Удаление и архивация.** Колонка `is_archived` и партиции есть, чтение фильтрует `is_archived = FALSE` [25][27].
API архивации или удаления потока в `emmett-postgresql` 0.42.4 не найдено.

## Message DB (Eventide)

**Таблица** — одна, `message_store.messages` [33][37]: `global_position bigserial PK`, `position bigint`,
`time timestamp without time zone DEFAULT (now() AT TIME ZONE 'utc')`, `stream_name text`, `type`, `data jsonb`,
`metadata jsonb`, `id uuid`. Индексы:

- unique `messages_id (id)`;
- unique `messages_stream (stream_name, position)`;
- `messages_category (category(stream_name), global_position, category(metadata->>'correlationStreamName'))`.

Таблицы потоков нет: версия потока каждый раз считается как `max(position)` [34]. README: position без дыр,
у global position дыры возможны [37].

**Защита от пропуска: advisory lock на категорию.** `write_message` сначала вызывает `acquire_lock(stream_name)`
→ `pg_advisory_xact_lock(hash_64(category))`, где `hash_64` — первые 64 бита md5 [34][35]. Документация:
все записи в потоки одной категории встают в очередь, что «ensures that write of a message to a stream does not
complete after a consumer has already proceeded past its position» [38]. `nextval` выполняется под блокировкой,
поэтому внутри категории порядок `global_position` совпадает с порядком коммитов. Читатель
`get_category_messages` фильтрует одну категорию: `category(stream_name) = $1 AND global_position >= $2 ORDER BY global_position` [36].
Чтения всех категорий среди серверных функций нет [37].

**Цена:** запись в категорию сериализована до конца транзакции; каждая запись выполняет `max(position)` [34].
Пакет пишется несколькими `write_message` в одной транзакции; писать в разные потоки одной транзакцией
документация не рекомендует [38].

**Ожидаемая версия.** `expected_version bigint DEFAULT NULL`; у пустого потока версия `-1`. При несовпадении —
`RAISE EXCEPTION 'Wrong expected version: % (Stream: %, Stream Version: %)'` без своего SQLSTATE [34][38].

**Время и метаданные.** `time` — `timestamp` без зоны, «does not include a time zone» [37]. Из метаданных
индексируется `correlationStreamName` и используется параметром `correlation` для pub/sub [33][36].
Causation на уровне БД не выделен.

**Удаление.** Серверных функций нет; скрипт `clear-messages.sh` делает `TRUNCATE message_store.messages RESTART IDENTITY` [39].

## Сравнение

| | EventStore | Marten | Emmett | Message DB |
|---|---|---|---|---|
| Таблицы | `streams` + `events` + `stream_events` (M:N) | `mt_streams` + `mt_events` | `emt_streams` + `emt_messages`, LIST-партиции | одна `messages` |
| Таблица на агрегат | нет | нет | нет (партиции по `partition`) | нет |
| Глобальная позиция | `stream_version` в `$all` (строка-счётчик) | `seq_id` из sequence | `global_position` из sequence + `xid8` | `bigserial` |
| Дыры | нет (кроме hard delete) | да | да | да |
| Против пропуска | row lock строки `$all` | high-water mark + liveness probe | `xid < pg_snapshot_xmin`, курсор `(xid, pos)` | advisory xact lock на категорию |
| Цена на запись | сериализация всех append | `nextval` | колонка + индекс | сериализация в категории, `max(position)` |
| Цена у читателя | нет | задержка, детектор, риск skip | задержка на долгих транзакциях | только чтение по категории |
| Проверка версии | pre-read + unique | SQL-функция (`MT003`) + unique | условный `UPDATE` / PK | SQL-функция |
| Ошибка | `{:error, :wrong_expected_version}` | `EventStreamUnexpectedMaxEventIdException`, `ConcurrencyException` | `ExpectedVersionConflictError` | `RAISE EXCEPTION 'Wrong expected version…'` |
| Время | `timestamptz`, из приложения | `timestamptz`, БД или приложение | `timestamptz DEFAULT now()` | `timestamp` UTC без зоны |
| Correlation / causation | колонки `uuid` | opt-in колонки | в `jsonb` | `correlationStreamName` в `jsonb` |
| Удаление / архив | soft `deleted_at`, hard за флагом | `is_archived`, compaction | колонка `is_archived`, API нет | нет |

## Развилки

1. **Счётчик в строке под row lock** (EventStore): позиции без дыр в порядке коммитов, читателю ничего не нужно.
   Цена — все append в схеме идут последовательно; hard delete оставляет дыры в `$all`.
2. **Sequence + advisory lock на раздел** (Message DB): порядок гарантирован только внутри раздела, читать можно
   только по разделу. Цена — сериализация записи в раздел до коммита; ключ блокировки — 64-битный хэш имени.
3. **Sequence + `xid8` + `pg_snapshot_xmin`** (Emmett): запись не блокируется. Цена — колонка и индекс, курсор из пары
   `(xid, position)`, задержка читателя на время долгой транзакции. В `0.42.4` курсор ещё одномерный.
4. **Sequence + high-water mark на читателе** (Marten): запись не блокируется. Цена — детектор дыр с проверкой живых
   транзакций, журнал пропусков, tombstone-строки; при принудительном skip событие теряется для проекций.
5. **Состояние потока:** отдельная строка потока с версией (EventStore, Marten, Emmett) — условный `UPDATE` или row
   lock на поток; либо без таблицы потоков, `max(position)` под блокировкой (Message DB).
6. **Где проверяется версия:** в приложении с unique-индексом как страховкой (EventStore) либо в SQL-функции или
   условном `UPDATE` в той же операции (Marten, Emmett, Message DB).
7. **Удаление:** флаг soft delete с триггерной защитой от `DELETE` (EventStore); флаг архива с партициями hot/cold
   (Marten, схема Emmett); удаление старой части потока со снапшотом (Marten compaction); только полная очистка
   (Message DB).

## Не найдено

- **EventStore:** документированной оценки пропускной способности при сериализации на строке `$all` нет — вывод
  сделан из SQL. Страница `hexdocs.pm/eventstore/event-store.html` отвечает 404 после редиректа, поэтому гайды
  цитируются из репозитория на теге.
- **Marten:** класс `EventStreamUnexpectedMaxEventIdException` в репозитории marten на теге не найден — его связь
  с `ConcurrencyException` не проверена. Текущая Rich-проверка версии (`Weasel.Storage.UpdateStreamVersionOperationBase`)
  лежит в Weasel и не прочитана. API жёсткого удаления целого потока не найдено.
- **Emmett:**
  - Причина перевода курсора на `(transaction_id, global_position)` в master не объяснена.
  - Может ли одномерный курсор `0.42.4` пропустить событие с меньшим `global_position` и большим xid на границе
    батча — это вывод из кода, проект его не подтверждает.
  - Документация Emmett механизм порядка не описывает.
  - Correlation/causation и API архивации не найдены.
  - Версия, с которой появился `xid8`, не установлена.
- **Message DB:** обсуждения коллизий `hash_64` между категориями и конвенций causation в клиенте Eventide не найдено.

## Источники

1. commanded/eventstore `v1.4.8` (`0bf4f2e`), `lib/event_store/sql/init.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/sql/init.ex
2. там же, `lib/event_store/sql/statements/insert_events.sql.eex`, `insert_events_any_version.sql.eex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/sql/statements/insert_events.sql.eex
3. там же, `lib/event_store/storage/appender.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/storage/appender.ex
4. там же, `lib/event_store/streams/stream_info.ex`, `lib/event_store/streams/stream.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/streams/stream_info.ex
5. там же, `lib/event_store.ex`, `lib/event_store/sql/statements/query_stream_events_forward.sql.eex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store.ex
6. там же, `guides/Usage.md` — https://github.com/commanded/eventstore/blob/v1.4.8/guides/Usage.md
7. там же, `guides/Subscriptions.md` — https://github.com/commanded/eventstore/blob/v1.4.8/guides/Subscriptions.md
8. там же, `lib/event_store/recorded_event.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/recorded_event.ex
9. там же, `lib/event_store/sql/statements/soft_delete_stream.sql.eex`, `hard_delete_stream.sql.eex`, `lib/event_store/storage/delete_stream.ex` — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/sql/statements/hard_delete_stream.sql.eex
10. commanded/eventstore, коммит `4a88a29` (master, не в теге) — https://github.com/commanded/eventstore/commit/4a88a29
11. commanded/commanded `v1.4.11` (`91d97bc`), `lib/commanded/aggregates/aggregate.ex`, `lib/commanded/aggregates/execution_context.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/aggregates/aggregate.ex
12. JasperFx/marten `V9.33.0` (`eb6263d`), `src/Marten/Events/Schema/EventsTable.cs`, `StreamsTable.cs` — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/Schema/EventsTable.cs
13. там же, `src/Marten/Events/Schema/QuickAppendEventFunction.cs` — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/Schema/QuickAppendEventFunction.cs
14. там же, `src/Marten/Events/Operations/QuickAppendEventsOperationBase.cs` — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/Operations/QuickAppendEventsOperationBase.cs
15. там же, `src/Marten/Events/EventGraph.FeatureSchema.cs` — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/EventGraph.FeatureSchema.cs
16. там же, `src/Marten/Events/Daemon/HighWater/` (`GapDetector.cs`, `GapLivenessProbe.cs`, `HighWaterDetector.cs`, `HighWaterStatisticsDetector.cs`), `src/Marten/Events/Schema/EventProgressionSkippingTable.cs` — https://github.com/JasperFx/marten/tree/V9.33.0/src/Marten/Events/Daemon/HighWater
17. там же, `docs/events/projections/async-daemon.md` (martendb.io/events/projections/async-daemon) — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/projections/async-daemon.md
18. там же, `docs/events/appending.md` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/appending.md
19. там же, `docs/events/optimizing.md` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/optimizing.md
20. там же, `docs/scenarios/command_handler_workflow.md` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/scenarios/command_handler_workflow.md
21. там же, `docs/events/archiving.md`, `src/Marten/Events/Archiving/ArchiveStreamFunction.cs` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/archiving.md
22. там же, `docs/events/compacting.md` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/compacting.md
23. там же, `docs/events/metadata.md` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/metadata.md
24. там же, `docs/events/storage.md` — https://github.com/JasperFx/marten/blob/V9.33.0/docs/events/storage.md
25. event-driven-io/emmett `0.42.4` (`dc0b5ac`), `src/packages/emmett-postgresql/src/eventStore/schema/tables.ts` — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/tables.ts
26. там же, `schema/appendToStream.ts` — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/appendToStream.ts
27. там же, `schema/readMessagesBatch.ts`, `schema/storeProcessorCheckpoint.ts` — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/readMessagesBatch.ts
28. там же, `schema/migrations/0_42_4/index.ts` — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/migrations/0_42_4/index.ts
29. там же, `eventStore/postgreSQLEventStore.ts`, `src/packages/emmett/src/eventStore/expectedVersion.ts`, `src/packages/emmett/src/commandHandling/handleCommand.ts` — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/postgreSQLEventStore.ts
30. event-driven-io/emmett master (`d1882f6`), `schema/readMessagesBatch.ts` — https://github.com/event-driven-io/emmett/blob/d1882f692014366b7fef28f0e1cec925590dd697/src/packages/emmett-postgresql/src/eventStore/schema/readMessagesBatch.ts
31. Документация Emmett, PostgreSQL event store — https://event-driven-io.github.io/emmett/event-stores/postgresql.html
32. O. Dudycz, «How Postgres sequences issues can impact your messaging guarantees», 2022-10-28 (статья автора Emmett) — https://event-driven.io/en/ordering_in_postgres_outbox/
33. message-db/message-db `v1.3.0` (`e6999a6`), `database/tables/messages.sql`, `database/indexes/` — https://github.com/message-db/message-db/blob/v1.3.0/database/tables/messages.sql
34. там же, `database/functions/write-message.sql`, `stream-version.sql` — https://github.com/message-db/message-db/blob/v1.3.0/database/functions/write-message.sql
35. там же, `database/functions/acquire-lock.sql`, `hash-64.sql` — https://github.com/message-db/message-db/blob/v1.3.0/database/functions/acquire-lock.sql
36. там же, `database/functions/get-category-messages.sql` — https://github.com/message-db/message-db/blob/v1.3.0/database/functions/get-category-messages.sql
37. там же, `README.md` — https://github.com/message-db/message-db/blob/v1.3.0/README.md
38. Документация Message DB, Server Functions (исходник eventide-project/docs `c396e76`, `user-guide/message-db/server-functions.md`) — http://docs.eventide-project.org/user-guide/message-db/server-functions.html
39. message-db/message-db `v1.3.0`, `database/clear-messages.sh` — https://github.com/message-db/message-db/blob/v1.3.0/database/clear-messages.sh
