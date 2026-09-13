# Готовые решения: схема event store на PostgreSQL и глобальный порядок

Type: research
Status: resolved
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как устроено хранение событий на PostgreSQL в Commanded EventStore, Marten, Emmett и Message DB:

- таблицы: общая таблица событий, таблица потоков, таблица на агрегат; колонки и индексы;
- глобальная позиция: как назначается (sequence, bigserial, xid) и как читатель по позиции не пропускает
  событие, закоммиченное позже события с большим номером (пропуски sequence, конкурентные транзакции);
  цена механизма на запись;
- проверка ожидаемой версии потока при append: механизм и ошибка;
- точность времени события, метаданные (correlation / causation), удаление и архивация потоков.

Нужно для тикета «Модель потока и таблица событий». Отправная точка `:core` — `map.md`, Notes.

## Answer

- Таблица на агрегат не встречается ни в одном из четырёх решений. EventStore: `streams` + `events` + `stream_events`
  (M:N, поток `$all`). Marten и Emmett: таблица потоков + общая таблица событий (у Emmett — LIST-партиции).
  Message DB: одна `messages`, версия потока — `max(position)`.
- EventStore: глобальная позиция — счётчик в строке `$all`, `UPDATE` берёт row lock до коммита. Номера идут в порядке
  коммитов без дыр, но все append в схеме сериализуются.
- Marten: `seq_id` из sequence, запись не блокируется. Читатель (async daemon) продвигает high-water mark по сплошному
  префиксу и держит дыру, пока жива транзакция, которая могла её занять (`pg_stat_activity`, `pg_snapshot_xip`).
  Мёртвые дыры пропускаются с записью в `mt_high_water_skips`; принудительный skip может потерять событие.
- Emmett: sequence + `transaction_id xid8`. Читатель берёт только `transaction_id < pg_snapshot_xmin(pg_current_snapshot())`
  в порядке `(xid, position)`. Запись без блокировок, чтение задерживается долгими транзакциями. В `0.42.4` курсор ещё
  одномерный, в master — пара `(xid, position)`.
- Message DB: `bigserial` с дырами; `pg_advisory_xact_lock(hash_64(category))` сериализует запись в категорию, поэтому
  порядок гарантирован только при чтении по категории.
- Проверка версии:
  - EventStore — pre-read + unique `(stream_id, stream_version)` → `{:error, :wrong_expected_version}`;
  - Marten — SQL-функция (`MT003` → `EventStreamUnexpectedMaxEventIdException`, `ConcurrencyException`);
  - Emmett — условный `UPDATE` / PK → `ExpectedVersionConflictError`, причём `STREAM_EXISTS` и `STREAM_DOES_NOT_EXIST`
    в PostgreSQL не проверяются;
  - Message DB — `RAISE EXCEPTION 'Wrong expected version…'`.
- Время: `timestamptz` у EventStore (задаёт приложение), Marten (БД или приложение) и Emmett (`now()`);
  `timestamp` без зоны у Message DB. Correlation/causation: колонки `uuid` в EventStore, opt-in колонки в Marten,
  `jsonb` в Emmett и Message DB.
- Удаление и архив:
  - EventStore — soft `deleted_at` и hard delete за флагом с триггерной защитой;
  - Marten — `is_archived` (+ партиции hot/cold) и compaction;
  - Emmett — колонка `is_archived` без API;
  - Message DB — только `TRUNCATE`.

[Отчёт](../research/01-event-store-schema.md)
