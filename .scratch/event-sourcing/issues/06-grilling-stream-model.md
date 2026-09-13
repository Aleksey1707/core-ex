# Модель потока и таблица событий

Type: grilling
Status: resolved
Blocked by: 01, 12
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Где и в какой форме event-sourced агрегат хранит события:

- переиспользовать таблицу событий агрегата (`Core.Es.Event.Repo.Pg.Schema`, таблица на агрегат) или
  завести общую таблицу событий;
- нужна ли глобальная позиция и какой механизм гарантирует, что читатель по позиции не пропустит
  событие конкурентной транзакции;
- достаточно ли unique `(aggregate_id, aggregate_version)` как проверки ожидаемой версии, когда строки
  состояния нет;
- точность `at` (сейчас `:utc_datetime`, секунды);
- кто поставляет DDL: библиотека (как `Core.Outbox.Migration`) или потребитель (как таблицу событий
  сейчас).

## Answer

- Одна таблица `es_events` для event-sourced и state-stored агрегатов, DDL — `Core.Es.Migration` (`up/0` / `down/0`,
  делегирование как у outbox); таблица на агрегат уходит, контракт state-stored меняется с записью в `CHANGELOG.md`.
- Ключ потока — тип агрегата и `aggregate_id`; тип — опция `type:` у `use Core.Es.Event.Codec`, только колонка,
  конверт не меняется.
- Проверка ожидаемой версии — unique `(тип, aggregate_id, aggregate_version)` + `insert_all` с `on_conflict: :nothing`
  и сверкой числа строк; таблицы потоков нет.
- Глобальная позиция — `(xid, номер)`: `xid xid8 default pg_current_xact_id()`, номер из identity; читатель берёт
  `xid < pg_snapshot_xmin(pg_current_snapshot())` в порядке `(xid, номер)`; append в поток, где есть событие с `xid`
  больше текущего, — `:version_mismatch`, иначе выдача переставляет версии потока. High-water mark отвергнут за детектор
  дыр.
- `at` — секунды (`Es.Event.At`); порядок держат версия и позиция.
- `payload` — jsonb библиотеки, `by_id` без FK; у схемы уходят `table:`, `by_schema:`, `payload_type:`.
- Перенос существующих таблиц событий пишет потребитель по инструкции `CHANGELOG.md`: внутри потока — по возрастанию
  версии, до первой записи нового кода.
- Не проверено на нагрузке: задержка чтения на пишущих транзакциях кластера и частота ложного `:version_mismatch`.
- Термины «Поток событий», «Тип агрегата», «Глобальная позиция» — в `CONTEXT.md`, раздел «Хранение».

[ADR-0008](../../../docs/adr/0008-shared-event-table-xid8-position.md)

## Comments

- 2026-09-13 — ограничение из тикета [«Своя реализация или готовая библиотека»](12-grilling-build-or-adopt.md):
  глобальный порядок не заставляет запись в разные потоки ждать commit чужой транзакции — строка-счётчик под
  row lock (EventStore) и advisory lock на категорию (Message DB) исключены; остаются `xid8 < pg_snapshot_xmin`
  (Emmett) и high-water mark (Marten). Не проверено на нагрузке.
- 2026-09-13 — раунд 1:
  - общая таблица событий для обоих видов агрегатов — event-sourced и state-stored; таблица на агрегат уходит,
    контракт state-stored меняется с записью в `CHANGELOG.md`;
  - проверка ожидаемой версии — unique `(поток, версия)` + `insert_all` с `on_conflict: :nothing` и сверкой числа
    строк; таблицы потоков нет; удаление и архивация потока — вопрос тикета «Контракт репозитория event-sourced
    агрегата»;
  - `at` — секунды, как сейчас (`Es.Event.At`); порядок задают версия и позиция, лаг проекции меряется по `at`;
  - глобальная позиция нужна (ADR-0007); механизм — после проверки на PostgreSQL 18.
- 2026-09-13 — раунд 2 (после проверки на PostgreSQL 18.4: читающая транзакция `pg_snapshot_xmin` не держит,
  пишущая держит по всему кластеру; `ORDER BY xid, position` переставляет версии потока, если xid назначен до
  чтения потока; страж `NOT EXISTS (… xid > pg_current_xact_id())` это ловит):
  - глобальная позиция — пара `(xid, номер)`: `xid xid8 default pg_current_xact_id()` и номер из identity;
    читатель берёт `xid < pg_snapshot_xmin(pg_current_snapshot())` по `(xid, номер)`; append отвергает запись,
    если в потоке есть событие с `xid` больше текущего, — `:version_mismatch` (ложный конфликт, действует и на
    state-stored); high-water mark отвергнут за детектор дыр;
  - тип агрегата — опция `type:` у `use Core.Es.Event.Codec`, только колонка, конверт не меняется; ключ потока —
    (тип агрегата, `aggregate_id`);
  - DDL — `Core.Es.Migration` (`up/0` / `down/0`, делегирование как у outbox), таблица `es_events`, `payload` —
    jsonb, `by_id` без FK; unique `(тип, aggregate_id, aggregate_version)` и индекс `(xid, номер)`;
    `table:` / `by_schema:` / `payload_type:` у схемы уходят;
  - перенос существующих таблиц событий state-stored пишет потребитель по инструкции `CHANGELOG.md`; хелпера нет.
