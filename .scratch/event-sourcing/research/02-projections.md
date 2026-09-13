# Готовые решения: проекции, подписки и чекпоинты

## Вопрос

Тикет: [02-research-projections](../issues/02-research-projections.md). Как устроены проекции в Commanded
(+ commanded_ecto_projections, EventStore), Marten, Emmett и Message DB: виды, источник асинхронной проекции,
чекпоинт и его атомарность с read-моделью, идемпотентность, пересборка без остановки записи, порядок и
конкурентность, поведение при ошибке.

Версии на 2026-09-13: commanded v1.4.11, commanded_ecto_projections (CEP) v1.4.0, eventstore v1.4.8,
Marten V9.33.0 с JasperFx.Events 2.67.0 (версия закреплена в `Directory.Packages.props`), Emmett 0.42.4,
Message DB v1.3.0, Eventide docs и consumer-postgres — master. Пометка «вывод из кода» — следствие, которого
в тексте источника нет.

## Commanded + commanded_ecto_projections + EventStore

**Виды.** Проекция — event handler (GenServer) на подписке; синхронной проекции в транзакции записи нет.
`consistency: :strong` только блокирует dispatch команды до обработки событий: «strong consistency does not
imply a transaction covers the command dispatch and event handling… if event handling fails the events will
have still been persisted»; по умолчанию `:eventual` [1]. Объявление: `use Commanded.Projections.Ecto,
application:, repo:, name:` и `project %Event{}, metadata, fn multi -> Ecto.Multi… end` [4].

**Источник.** Persistent-подписка EventStore к `$all` (по умолчанию) или к одному потоку (`subscribe_to`)
[1]. `$all` — поток `stream_id = 0`, номер события в нём выдаётся в транзакции вставки:
`UPDATE streams SET stream_version = stream_version + n WHERE stream_id = 0` [8]; блокировка этой строки
сериализует конкурентные append, поэтому в `$all` нет дыр и перестановок (вывод из кода). Новые события:
триггер `AFTER INSERT OR UPDATE ON streams` вызывает `pg_notify` с диапазоном версий; один процесс на ноду
слушает канал, дочитывает события из БД и раздаёт подпискам [6][8]. Пришёл номер с пропуском — подписка
уходит в catch-up и читает хранилище [9]; при переполнении очереди (`max_size`, 1000) — тоже чтение из БД [7].

**Чекпоинт.** Два независимых уровня:

- EventStore: `subscriptions.last_seen` по `(stream_uuid, subscription_name)`, `UPDATE … SET last_seen` после
  ack [8]. `checkpoint_threshold` (по умолчанию 1 — после каждого ack) и `checkpoint_after`; при пороге > 1
  «events might be replayed when the subscription resumes» [7][9]. Доставка — at-least-once [6].
- CEP: таблица `projection_versions(projection_name text PK, last_seen_event_number bigint, timestamps)` [4].
  `update_projection` собирает один `Ecto.Multi`: первым шагом `INSERT … ON CONFLICT (projection_name)
  DO UPDATE SET last_seen_event_number = n WHERE last_seen_event_number < n`; строка не обновилась →
  `{:error, :already_seen_event}` → транзакция откатывается, handler возвращает `:ok`, событие ack-ается;
  затем операции проекции; всё — одна `repo.transaction` [4]. Документация: «executed in a database
  transaction including an idempotency check to guarantee an event cannot be projected more than once» [4].
  `after_update/3` вызывается после коммита [4].
- Handler хранит в памяти `last_seen_event` и ack-ает события с номером ≤ ему без вызова `handle` [1].

Чекпоинт read-модели атомарен с read-моделью, чекпоинт подписки пишется отдельно; расхождение между ними
закрывает проверка `last_seen_event_number` (вывод из кода).

**Пересборка.** Руководство CEP: `DELETE FROM projection_versions WHERE projection_name = …`,
`TRUNCATE … RESTART IDENTITY`, плюс «reset the event store subscription… specific to whichever event store
you are using» [5]. В Commanded это `mix commanded.reset --app --handler`: handler вызывает `before_reset/0`,
затем `unsubscribe` + `EventStore.delete_subscription` и переподписывается со `start_from` [1][3]; удаление
подписки «will remove the subscription checkpoint» [6]. Запись событий не останавливается, read-модель до
конца replay неполна (вывод из кода). Версионирования проекции нет; `start_from` действует только при
создании подписки [1], поэтому новое `name:` даёт новую подписку и новую строку `projection_versions`
(вывод из кода).

**Порядок и конкурентность.** По умолчанию один процесс, «processing events one at a time in order» [1].
`concurrency: N` + `partition_by/2`: события одной партиции обрабатывает по порядку один экземпляр; только
`:eventual` (`:strong` с `concurrency` → `ArgumentError`); с `batch_size` несовместимо [1]. На стороне
EventStore — `concurrency_limit`, `partition_by`, `buffer_size` (1 in-flight) [6][7]. Именованная подписка
подключается в одном экземпляре на кластер — advisory lock [6][9]. Батч: `batch_size` + `handle_batch/1`,
«There is no partial acknowledgement» [1].

**Ошибки.** `error/3` возвращает `{:retry, ctx}`, `{:retry, delay, ctx}`, `:skip` (ack) или `{:stop, reason}`
[1]. Без `error/3` — stop; под `permanent`-супервизором «It will likely crash again as it will reprocess the
problematic event» [1]. Настройка приложения `on_event_handler_error: :backoff` — экспоненциальная задержка
от 1 с до 24 ч [1][2]. DLQ нет.

## Marten

**Виды.** Lifecycle: Inline — «executed at the time of event capture and in the same unit of work to persist
the projected documents», выполняется при `IDocumentSession.SaveChanges()`; Live — в памяти по запросу, без
сохранения; Async — «executed by a background process (eventual consistency)» [10]. Рецепты: Single Stream,
Multi Stream, Event Projection, Flat Table, Custom [10]. Регистрация —
`opts.Projections.Add<P>(ProjectionLifecycle.Async)` [11].

**Источник.** Async daemon живёт в процессе приложения, «requires no other infrastructure besides
Postgresql», обрабатывает события «in order» [11]. Читает `mt_events` по глобальному `seq_id` до high water
mark — «the furthest known event sequence… all events with that sequence or lower can be safely processed in
order» [11]. Опрос: `FastPollingTime` 250 мс, `SlowPollingTime` 1 с [15]; опция `UseListenNotifyForEventAppends`
(по умолчанию false) шлёт `pg_notify('mt_events_appended')` и будит детектор, опрос остаётся страховкой [14].

Дыры (с 9.23): mark «stops under any hole»; демон проверяет, жива ли транзакция, которая могла занять номер
(`pg_locks`, `pg_stat_activity`, `pg_snapshot_xip`), держит mark, пока она жива, и пропускает дыру только
доказанно мёртвую, записывая это в `mt_high_water_skips` [11][14]. `SkipStaleGapsDespiteLiveTransactionsAfter`
(по умолчанию null) включает пропуск по таймауту, и тогда «an append that commits inside the skipped range
will never be projected» [11]. Документация советует QuickAppend как реже дающий дыры [11].

**Чекпоинт.** `mt_event_progression(name PK, last_seq_id bigint, last_updated)`, строка на shard [13].
`RecordProgress` ставит `UpdateProjectionProgress` в ту же очередь `ProjectionUpdateBatch`, что и операции
документов, всё уходит одним `ExecuteBatchAsync` [13]. Update оптимистичный:
`update … set last_seq_id = ceiling where name = ? and last_seq_id = floor`; 0 строк →
`ProgressionProgressOutOfOrderException` [13]. Повтор диапазона guard не пропустит; непрерывный путь пишет
документы через `UPSERT` / `ON CONFLICT` [12].

**Пересборка.** `daemon.RebuildProjectionAsync(name, shardTimeout, token)` или CLI `projections --rebuild`;
пересобираются и Async, и Inline [11][12]. Шаги в JasperFx: остановить агентов проекции → проверить high
water → `TeardownExistingProjectionStateAsync` → переиграть каждый shard от 0 до зафиксированного mark с
`RebuildErrors` → `StopAndDrain`; для Inline в конце удаляется progress [15]. Запись событий не блокируется,
но между teardown и концом replay read-модель неполна (вывод из кода). Отмена оставляет progress
консистентным, повторный запуск «starts by resetting the cell» [12]. Без простоя — blue/green: поднять
`ProjectionVersion`, новая версия «writes to separate database tables», как Async догоняет, после чего
переключается трафик [12]. `UseOptimizedProjectionRebuilds` пересобирает поток за потоком в обратном порядке
последнего изменения и корректен, только если у потока ровно одна single stream проекция [12]. Лимит
параллельных пересборок — `max(1, MaxPoolSize / 8)` на БД [12].

**Порядок и конкурентность.** `Solo` — все shard на одной ноде, нода предполагается одна; `HotCold` —
лидер-выбор на advisory lock «individually for each projection on each tenant database», «exactly one running
process» [11]. Распределение — по типу проекции [11]. Ограничители: `MaxConcurrentEventLoadsPerDatabase = 4`,
`MaxConcurrentBatchWritesPerDatabase = 4` [11].

**Ошибки.** `SkipApplyErrors`, `SkipSerializationErrors`, `SkipUnknownEvents`: в непрерывной работе по
умолчанию True, при пересборке False; пропуск выключен — «the individual projection will be paused»,
пересборка останавливается [11]. Пропущенные события попадают в `DeadLetterEvent` (`mt_doc_deadletterevent`),
чтобы «replay events later after the fix» [11]. Сбои Marten/PostgreSQL — ретраи Polly [11].

## Emmett

**Виды.** Inline: `projections: projections.inline([...])` в опциях event store; «Inline registration means
that projections run in the same database transaction as appending events. Either both succeed or both fail»
[16]. Реализация — `beforeCommitHook` в `appendToStream`, `handleProjections` получает ту же транзакцию [17].
Фабрики: `pongoSingleStreamProjection`, `pongoMultiStreamProjection`, `postgreSQLRawSQLProjection` и др.
[16][17]. Асинхронные в документации: «Async projections are also available; we'll document them soon» [16];
в коде — `postgreSQLEventStoreConsumer` с процессорами `projector` и `reactor` [21][22]. Всё ниже про async —
только по коду 0.42.4.

**Источник.** Опрос `emt_messages` [22]: `global_position` из sequence, `transaction_id xid8` =
`pg_current_xact_id()` при append [17][18]. Выборка — `transaction_id < pg_snapshot_xmin(pg_current_snapshot())`,
`ORDER BY transaction_id, global_position` [19]: видны только транзакции, завершившиеся до старейшей
активной, поэтому незакоммиченная транзакция не создаёт пропуска (вывод из кода). Пуллер: пока пачки
неполные, пауза удваивается от 100 до 1000 мс, после полной пачки — `pullingFrequencyInMs` [22]. LISTEN/NOTIFY
в пакете `emmett-postgresql` не используется (поиск по коду). Один consumer читает пачку и параллельно отдаёт
её всем активным процессорам (`Promise.allSettled`) [22].

**Чекпоинт.** `emt_processors(processor_id, partition, version PK, last_processed_checkpoint text,
last_processed_transaction_id xid8, status, processor_instance_id…)` [18]. PostgreSQL-процессор оборачивает
обработку пачки в `pool.withTransaction`, и после каждого сообщения вызывает `checkpoints.store` в той же
транзакции [21][22]. `store_processor_checkpoint` обновляет строку только при
`last_processed_checkpoint = p_check_position` и возвращает код: 1 записано, 0 уже стоит, 2 mismatch, 3 другой
процесс впереди [20]. Неуспешная запись не двигает чекпоинт в памяти (`// TODO: Add correct handling of the
storing checkpoint`) [21]. Идемпотентность: `wasMessageHandled` пропускает сообщения с позицией ≤ последнего
чекпоинта [21].

**Пересборка.** `rebuildPostgreSQLProjections({ projections })` — consumer с
`stopWhen: { noMessagesLeft: true }` и projector с `truncateOnStart: true` (вызов `projection.truncate`),
блокировка берётся с retry: 100 попыток, 100–5000 мс [21][23]. Процессор берёт `pg_try_advisory_xact_lock` по
ключу `partition:projectionName:version`, записывает себя владельцем в `emt_processors` (перехват, если
`status = 'stopped'` или `last_updated` старше `lock_timeout_seconds`, 300) и переводит проекцию в
`emt_projections` в статус `async_processing`; при освобождении возвращает `active` [23]. Inline при append
берёт shared advisory lock с тем же ключом и применяет проекцию, только если lock получен и статус `active`,
иначе пропускает её [17][23]. Значит, append во время пересборки не блокируется, а события догоняет
асинхронный процессор (вывод из кода). `version` входит в PK процессоров и проекций, версии проекции живут
параллельно [18]; процедуры blue/green в документации нет.

**Порядок и конкурентность.** Один владелец на `(processor_id, partition, version)` [23]; сообщения пачки
обрабатываются последовательно [21]. `partition` — ключ LIST-партиционирования таблиц, а не группа
потребителей [18].

**Ошибки.** Исключение в обработчике откатывает транзакцию пачки и выключает процессор: «Error during message
processing… Stopping the processor.» [21]. Обработчик может вернуть `MessageProcessor.result.skip()` /
`stop()` [21]. Ретраев и DLQ в процессоре нет; consumer останавливается, когда активных процессоров не
осталось [22].

## Message DB (Eventide)

**Виды.** Message DB — хранилище сообщений на функциях PostgreSQL; проекций read-модели в нём нет,
`write_message` пишет одно сообщение [25]. В Eventide `EntityProjection` применяет события к сущности в
памяти при чтении из entity store (кэш, снапшоты): «When an entity is "retrieved", events from its event
stream are applied to it by the entity projection» [27] — аналог Live. Read-модели (view DB) — отдельные
библиотеки `view_data-commands` и `view_data-pg` [27], здесь не разбирались.

**Источник.** Consumer опрашивает категорию: `get_category_messages(category, position, batch_size,
correlation, consumer_group_member, consumer_group_size, condition)` → `global_position >= position ORDER BY
global_position LIMIT batch_size` [24][25]. Без новых сообщений — пауза `poll_interval_milliseconds` (100)
[26]. LISTEN/NOTIFY в `database/` нет. `global_position` «may have gaps», `position` в потоке «gapless» [24].
`write_message` берёт `pg_advisory_xact_lock(hash_64(category))` [25]: записи в одну категорию сериализованы до
коммита, и внутри категории порядок `global_position` совпадает с порядком коммитов (вывод из кода).

**Чекпоинт.** Position store: раз в `position_update_interval` (100) сообщений позиция пишется сообщением
`Recorded` в поток `{stream}+position[-identifier]`, чтение берёт последнее сообщение потока [26][28]. Запись
позиции отделена от работы обработчика, так что после рестарта повторяется до `position_update_interval`
сообщений (вывод из кода). Два consumer'а с одним identifier на одном потоке «will cause these consumers to
skip messages» [26]. Идемпотентность — забота обработчика: `sequence` сущности и `processed?(message_sequence)`
[27]; с consumer groups запись обязана использовать `expected_version` [26].

**Пересборка.** В документации не описана.

**Порядок и конкурентность.** Consumer group: `group_size`, `group_member` и условие
`MOD(@hash_64(cardinal_id(stream_name)), size) = member` — «any given stream is processed by a single
consumer, and that the consumer processing the stream is always the same consumer»; у каждого участника свой
`identifier` [25][26]. Размер группы и номер участника задаются параметрами старта [26].

**Ошибки.** «errors that are raised in the course of a consumer doing its work should not be caught. The
purpose of an error is to signal a fatal, unrecoverable condition»; `error_raised(error, message_data)` по
умолчанию пробрасывает ошибку, не пробрасывать её допустимо только ради retry [26]. Встроенных retry и DLQ нет.

## Сравнительная таблица

| | Commanded + CEP | Marten | Emmett | Message DB / Eventide |
|---|---|---|---|---|
| Синхронная в TX записи | нет (`:strong` — ожидание) | Inline | inline (`beforeCommitHook`) | нет |
| Источник async | persistent-подписка `$all` | `seq_id` до high water mark | `global_position` + фильтр `xmin` | категория по `global_position` |
| Сигнал о новых событиях | LISTEN/NOTIFY + catch-up из БД | опрос; NOTIFY опционально | опрос | опрос |
| Порядок при конкурентных append | блокировка строки `$all` | high water mark + проверка живых TX | `transaction_id < pg_snapshot_xmin` | advisory lock на категорию |
| Где чекпоинт | `subscriptions.last_seen` + `projection_versions` | `mt_event_progression` | `emt_processors` | поток `…+position` |
| Атомарен с read-моделью | CEP — да, подписка — нет | да | да (на пачку) | нет |
| Guard повтора | `last_seen_event_number < n` | `last_seq_id = floor` | `checkpoint = expected`, `wasMessageHandled` | обработчик (`sequence`) |
| Пересборка | вручную: truncate + `commanded.reset` | `RebuildProjectionAsync`; blue/green через `ProjectionVersion` | `rebuildPostgreSQLProjections`; inline на время выключена | не описана |
| Параллелизм | `concurrency` + `partition_by` | 1 процесс на проекцию (HotCold) | 1 владелец на процессор | consumer group по хешу потока |
| Ошибка по умолчанию | stop; `error/3`: retry / skip / stop | skip → dead letter; при rebuild — stop | stop процессора | падение consumer'а |

## Развилки

Варианты и их цена по фактам выше; выбор для `:core` — в HITL-тикете. Точка отсчёта `:core`: таблица событий
у каждого агрегата своя, глобальной позиции нет (`map.md`, Notes).

1. **Синхронная проекция в TX записи или только асинхронная.** Sync (Marten Inline, Emmett inline): read-модель
   согласована с событиями, но ошибка проекции откатывает запись, append медленнее («they can slow your
   appends» [16]). Async: eventual consistency, ожидание требует отдельного механизма (`:strong` [1],
   `WaitForNonStaleProjectionDataAsync` [11]).
2. **Сквозной порядок для async.** Нужна позиция по всем агрегатам. (a) Строка-счётчик, обновляемая в TX
   append (EventStore `$all`), — сериализует все append. (b) Advisory lock по категории (Message DB) —
   сериализует append в категории, порядок только внутри неё. (c) Sequence + high water mark с проверкой
   живых транзакций (Marten) — сложный детектор, зависшая транзакция останавливает все проекции. (d) `xid8` +
   фильтр `pg_snapshot_xmin` (Emmett) — долгая транзакция задерживает всех читателей (вывод из кода).
3. **Сигнал о новых событиях.** Только опрос (Emmett, Message DB): задержка до интервала, холостые запросы.
   LISTEN/NOTIFY как будильник + чтение из БД (EventStore; Marten опционально): выделенное соединение на ноду,
   catch-up или опрос остаются страховкой.
4. **Где чекпоинт.** В TX read-модели (CEP, Marten, Emmett): повтор отсекает guard, но read-модель обязана
   лежать в той же БД, что и чекпоинт. Отдельно (EventStore, Eventide): at-least-once, идемпотентность на
   обработчике. CEP держит оба уровня.
5. **Пересборка.** На месте, teardown + replay (Marten, CEP, Emmett): read-модель неполна до конца replay.
   Параллельная версия (Marten `ProjectionVersion`, `version` в ключах Emmett): двойное хранение и отдельное
   переключение чтения. Inline-проекция на время пересборки: Emmett пропускает её по статусу, у Marten это не
   описано.
6. **Параллелизм.** Один обработчик на проекцию под лидер-локом (Marten HotCold, Emmett, EventStore): строгий
   порядок, пропускная способность одного процесса. Партиционирование по хешу потока (Commanded
   `partition_by`, Message DB consumer groups): порядок только внутри партиции, размер группы статический, в
   Commanded несовместимо со `:strong`.
7. **Реакция на ошибку.** Stop (Commanded, Emmett, Eventide): лаг растёт до ручного вмешательства. Skip +
   dead letter (Marten continuous): проекция идёт дальше, read-модель расходится до повторной обработки.
   Retry с backoff (Commanded `:backoff`): порядок сохраняется, проекция стоит на время повторов.

## Не найдено

- Emmett: документация асинхронных проекций и consumer'ов («we'll document them soon») — поведение описано
  только по коду 0.42.4. Не проверено, теряется ли для inline-проекции событие, записанное между последним
  чтением пересборки и возвратом статуса `active`. Ретраи, DLQ и партиционирование обработки не найдены.
- Marten: как Inline-проекция ведёт себя при новых append во время собственного `RebuildProjectionAsync`.
- Message DB / Eventide: процедура пересборки read-модели; библиотека `view_data-pg` не изучалась.
- Commanded / CEP: версионирование проекций, blue/green, DLQ.
- Сравнительные нагрузочные данные (задержка, пропускная способность) не искались; у Marten есть только замеры
  лимитов пересборки [12].

## Источники

1. commanded v1.4.11 (91d97bc), `lib/commanded/event/handler.ex` — L150–185 `start_from`, L269–316 Concurrency,
   L318–345 Consistency, L590–625 `error/3`, L1266–1275 already seen.
   https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/event/handler.ex ·
   https://hexdocs.pm/commanded/Commanded.Event.Handler.html
2. commanded v1.4.11, `lib/commanded/event/error_handler.ex`.
   https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/event/error_handler.ex
3. commanded v1.4.11, `lib/mix/tasks/commanded.reset.ex`, `lib/commanded/event_store/subscription.ex` (`reset/1`).
   https://github.com/commanded/commanded/blob/v1.4.11/lib/mix/tasks/commanded.reset.ex
4. commanded-ecto-projections v1.4.0 (e2252b8), `lib/projections/ecto.ex` L57–106,
   `priv/repo/migrations/20170609113553_create_projection_versions.exs`.
   https://github.com/commanded/commanded-ecto-projections/blob/v1.4.0/lib/projections/ecto.ex
5. commanded-ecto-projections v1.4.0, `guides/Usage.md` («Error handling», «Rebuilding a projection»).
   https://hexdocs.pm/commanded_ecto_projections/usage.html
6. eventstore v1.4.8 (0bf4f2e), `guides/Subscriptions.md`. https://hexdocs.pm/eventstore/subscriptions.html
7. eventstore v1.4.8, `lib/event_store.ex` L1120–1260 (опции persistent-подписки, «Subscription tuning»).
   https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store.ex
8. eventstore v1.4.8, `lib/event_store/sql/init.ex` L184–241, `lib/event_store/sql/statements/insert_events.sql.eex`
   L106–115, `subscription_ack.sql.eex`. https://github.com/commanded/eventstore/tree/v1.4.8/lib/event_store/sql
9. eventstore v1.4.8, `lib/event_store/subscriptions/subscription_fsm.ex` L128–175, L326, L689–735.
   https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/subscriptions/subscription_fsm.ex
10. Marten V9.33.0 (eb6263d), `docs/events/projections/index.md` L95–117, `inline.md` L4.
    https://martendb.io/events/projections/
11. Marten V9.33.0, `docs/events/projections/async-daemon.md`. https://martendb.io/events/projections/async-daemon.html
12. Marten V9.33.0, `docs/events/projections/rebuilding.md`. https://martendb.io/events/projections/rebuilding.html
13. Marten V9.33.0, `src/Marten/Events/Daemon/Progress/UpdateProjectionProgress.cs` L43–60,
    `src/Marten/Events/Daemon/Internals/ProjectionBatch.cs` L33–48, `src/Marten/Events/Schema/EventProgressionTable.cs`.
    https://github.com/JasperFx/marten/tree/V9.33.0/src/Marten/Events/Daemon
14. Marten V9.33.0, `src/Marten/Events/Daemon/HighWater/HighWaterDetector.cs`, `GapLivenessProbe.cs`,
    `PostgresqlListenWakeup.cs`, `src/Marten/Events/IEventStoreOptions.cs` L218–223.
    https://github.com/JasperFx/marten/tree/V9.33.0/src/Marten/Events/Daemon/HighWater
15. JasperFx V2.67.0 (3575a28), `src/JasperFx.Events/Daemon/JasperFxAsyncDaemon.cs` L490–505, L1675–1750;
    `DaemonSettings.cs` L118–139, L225. https://github.com/JasperFx/jasperfx/tree/V2.67.0/src/JasperFx.Events/Daemon
16. Emmett 0.42.4 (dc0b5ac), `src/docs/getting-started.md` L450–620.
    https://event-driven-io.github.io/emmett/getting-started.html
17. Emmett 0.42.4, `src/packages/emmett-postgresql/src/eventStore/postgreSQLEventStore.ts` L257–272,
    `schema/appendToStream.ts` L46–49, `projections/postgreSQLProjection.ts` L104–120.
    https://github.com/event-driven-io/emmett/tree/0.42.4/src/packages/emmett-postgresql/src/eventStore
18. Emmett 0.42.4, `…/eventStore/schema/tables.ts` L34–85.
    https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/tables.ts
19. Emmett 0.42.4, `…/eventStore/schema/readMessagesBatch.ts` L85–86.
    https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/readMessagesBatch.ts
20. Emmett 0.42.4, `…/eventStore/schema/storeProcessorCheckpoint.ts`.
    https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/storeProcessorCheckpoint.ts
21. Emmett 0.42.4, `src/packages/emmett/src/processors/processors.ts` L121–135, L505–590, L635–643.
    https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett/src/processors/processors.ts
22. Emmett 0.42.4, `…/eventStore/consumers/postgreSQLProcessor.ts` L240–270, `postgreSQLEventStoreConsumer.ts`
    L106–150, `messageBatchProcessing/index.ts` L70–120.
    https://github.com/event-driven-io/emmett/tree/0.42.4/src/packages/emmett-postgresql/src/eventStore/consumers
23. Emmett 0.42.4, `…/consumers/rebuildPostgreSQLProjections.ts`, `schema/processors/processorsLocks.ts` L30–125,
    `schema/projections/projectionsLocks.ts`, `projections/locks/postgreSQLProcessorLock.ts`.
    https://github.com/event-driven-io/emmett/tree/0.42.4/src/packages/emmett-postgresql/src/eventStore/projections/locks
24. Message DB v1.3.0 (e6999a6), `README.md` L223–252, L300–318.
    https://github.com/message-db/message-db/blob/v1.3.0/README.md
25. Message DB v1.3.0, `database/functions/get-category-messages.sql`, `write-message.sql`, `acquire-lock.sql`.
    https://github.com/message-db/message-db/tree/v1.3.0/database/functions
26. Eventide docs (913c3ce), `user-guide/consumers.md`. https://docs.eventide-project.org/user-guide/consumers.html
27. Eventide docs (913c3ce), `user-guide/entities.md` L60–80, `core-concepts/services/projections.md`,
    `user-guide/libraries.md` L193–201. https://docs.eventide-project.org/user-guide/entities.html
28. eventide-project/consumer-postgres (1619390), `lib/consumer/postgres/position_store.rb`.
    https://github.com/eventide-project/consumer-postgres/blob/1619390c50be9d573796cc8223827902a97b2e31/lib/consumer/postgres/position_store.rb
