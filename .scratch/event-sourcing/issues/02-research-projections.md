# Готовые решения: проекции, подписки и чекпоинты

Type: research
Status: resolved
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как устроены проекции в Commanded (+ commanded_ecto_projections), Marten, Emmett и Message DB:

- виды проекций: синхронная (в транзакции записи событий), асинхронная; как объявляются;
- источник асинхронной проекции: чтение event store по глобальной позиции, подписка через брокер,
  `LISTEN/NOTIFY`;
- чекпоинт: где хранится, как фиксируется атомарно с изменением read-модели, идемпотентность повторной
  обработки;
- пересборка проекции из истории без остановки записи;
- порядок и конкурентность обработки (один обработчик на проекцию, партиционирование); поведение при
  ошибке на событии (retry, остановка, пропуск, DLQ).

Нужно для тикетов «Проекции: синхронные, асинхронные, источник событий» и для тумана «Пересборка
проекций». Отправная точка `:core` — `map.md`, Notes.

## Answer

- Синхронная проекция в транзакции записи событий есть в Marten (Inline) и Emmett (inline через
  `beforeCommitHook`). В Commanded и Message DB её нет: `:strong` в Commanded только ждёт обработчики.
- Асинхронные проекции везде читают ту же PostgreSQL по глобальной позиции, брокера нет. Как узнают о новых
  событиях:
  - EventStore — LISTEN/NOTIFY плюс дочитывание из БД;
  - Marten — опрос, NOTIFY включается опцией (`UseListenNotifyForEventAppends`);
  - Emmett и Message DB — только опрос.
- Порядок при конкурентных append:
  - EventStore — блокировка строки `$all`;
  - Message DB — advisory lock на категорию;
  - Marten — high water mark с проверкой живых транзакций;
  - Emmett — фильтр `transaction_id < pg_snapshot_xmin`.
- Чекпоинт в одной транзакции с read-моделью, повтор отсекает условный UPDATE:
  - CEP — `last_seen_event_number < n`;
  - Marten — `last_seq_id = floor`;
  - Emmett — `checkpoint = expected`.

  Чекпоинт подписки EventStore и position stream Eventide пишутся отдельно: доставка at-least-once,
  идемпотентность на обработчике.
- Пересборка на месте — teardown и replay: Marten `RebuildProjectionAsync`, CEP — truncate и
  `mix commanded.reset`, Emmett `rebuildPostgreSQLProjections`. Запись не останавливается, но read-модель
  неполна до конца replay.
- Без простоя blue/green описан только у Marten (`ProjectionVersion`). В Emmett `version` входит в ключи, а
  inline-проекция на время асинхронной обработки пропускается по статусу. Message DB/Eventide пересборку не
  описывают.
- Параллелизм: Marten (HotCold), Emmett и EventStore держат один обработчик на проекцию через advisory lock.
  Партиционирование по потоку есть у Commanded (`partition_by`) и Message DB (consumer groups).
- Ошибка по умолчанию: Commanded, Emmett и Eventide останавливают обработку; в Commanded `error/3` даёт
  retry/skip/stop и backoff. Marten в непрерывном режиме пропускает событие в dead letter, при пересборке
  останавливается.
- Не подтверждено: асинхронная часть Emmett описана только по коду 0.42.4, поведение Inline Marten во время
  rebuild не описано.

[Отчёт](../research/02-projections.md)
