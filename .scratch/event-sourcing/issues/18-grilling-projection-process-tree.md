# OTP-дерево асинхронных проекций

Type: grilling
Status: resolved
Blocked by: 08
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как устроены процессы проекций:

- процесс на проекцию или один процесс на все проекции; чей супервизор — библиотечный со списком проекций или
  потребителя; где объявляется список проекций приложения;
- как `append` хранилища находит читателей для `wake` (Registry по типу агрегата, имена из конфига) и как `wake`
  схлопывается;
- отключаемость (`:ignore`, в test) и настройки `batch_size`, `retry_min_ms`, `retry_max_ms`, `poll_interval` —
  общие или на проекцию, `config/runtime.exs` и env;
- `trap_exit` и `:shutdown` с запасом на транзакцию пачки; синхронный прогон для тестов;
- место в `watch_list` и поведение процесса, пока проекция стоит в retry.

## Answer

- **Дерево.** Библиотечный `Core.Es.Projection.Supervisor`: потребитель ставит `{Core.Es.Projection.Supervisor,
  projections: [A, B], enabled: …}` в своё дерево; внутри `rest_for_one`: `Core.Es.Projection.Registry` →
  `one_for_one` читателей `Core.Es.Projection.Reader`, по одному на проекцию, имя процесса — модуль проекции. На старте
  `StartOpts`: модуль — `use Core.Es.Projection`, `name:` без дублей, иначе `ArgumentError`; список — в коде дерева, не
  в config. `child_spec` на проекцию и супервизор у приложения отвергнуты: дубль `name:` виден только там, где весь
  список.
- **`wake`.** `Registry` с `keys: :duplicate`: читатель в `init/1` регистрируется под типами агрегатов из `events:`;
  `Core.Es.Store.append` в `AfterCommit` — `Registry.dispatch` по типам пачки; Registry не запущен — `:ok`; второй
  супервизор на ноде — отказ старта. Имена из конфига и `wake` всех читателей отвергнуты.
- **Цикл** — исход и следующий тик:
  - `:processed` (пачка или старт с начала — `clear/0` и чекпоинт в начало) → `schedule(0)`, сброс backoff'ов;
  - `:idle` / `:locked` → `idle_min_ms` ×2 до `poll_interval_ms`; `wake` в ожидании — цикл сразу без сброса счётчика,
    во время цикла — `schedule(0)`;
  - `:retry` (исключение, exit, throw, недоступная БД, ошибка `clear/0`) → `retry_min_ms` ×2 до `retry_max_ms`, `wake`
    не ускоряет;
  - `:outdated` (чекпоинт новее своей `version:`) → `poll_interval_ms`, `wake` не ускоряет;
  - `flush_wakes` в начале и конце цикла; первый тик — таймер `idle_min_ms` из `init/1`, без запросов; пересборка — тот
    же `batch_size` и `schedule(0)`, отдельного размера пачки и паузы между пачками нет.
- **Retry.** Процесс жив, рестарта нет; `warning` на попытку с `projection=`, `position=`, `event_id=`, `attempt=` и
  причиной; попытка, начало и код ошибки — в state и telemetry цикла; `await` ждёт до таймаута. Колонки
  `retry_since` / `last_error` в `es_checkpoints` отвергнуты.
- **Остановка.** `trap_exit`, `terminate/2` только логирует; `shutdown:` дефолт 30 000 мс; отдельного таймаута
  транзакции пачки нет.
- **Опции** — общие на супервизоре, `StartOpts`; библиотека config и env не читает. Обязательны `projections:` и
  `enabled:`; дефолты: `batch_size` 100, `idle_min_ms` 50, `poll_interval_ms` 1 000, `retry_min_ms` 1 000,
  `retry_max_ms` 30 000, `shutdown` 30 000. Env — в `runtime.exs` потребителя, свод рекомендует `ES_PROJECTIONS_*`
  (длительности — `Core.DurationParser`). Переопределение на проекцию, `disabled: [имена]` и размер пачки пересборки —
  не сейчас, добавляются без поломки.
- **Отключение.** `enabled: false` → `:ignore` + `info`; `projections: []` → `:ignore` + `info` «пропущен: нет
  проекций»; отметки в `:persistent_term` нет. У процесса агрегата `enabled:` тоже обязательна.
- **Тесты.** `Core.Es.Projection.run_once(projection)` → `:processed | :idle | :locked | :outdated | {:error,
  Error.t()}` — одна пачка в вызывающем процессе, цикл читателя зовёт её же; внутри `Transact.run` — `raise`. Условие
  читателя — `xid < pg_snapshot_xmin(pg_current_snapshot()) OR xid = pg_current_xact_id_if_assigned()`: в транзакции с
  xid `pg_snapshot_xmin` равен своему xid, и sandbox-тест не видел бы своих событий; у транзакции пачки на проде своих
  событий нет. Тест с прогоном проекции — `async: false`: advisory lock и строка чекпоинта держатся до конца
  sandbox-транзакции. Тесты потребителя — `enabled: false`.
- **`watch_list`.** Каждый читатель под именем модуля проекции, `component: "es_projection:<name>"`, `required:` =
  `enabled`; хелпер `Core.Es.Projection.Supervisor.watch_list(projections)`.
- Цена: нода с `enabled: false` не будит — задержка до `poll_interval_ms` читателя другой ноды; читатели
  останавливаются по очереди — худший случай N × `shutdown`.
- Не проверено на нагрузке: холостые запросы — проекции × ноды до раза в `poll_interval_ms`; пересборка без паузы
  между пачками.
- `CONTEXT.md` не меняется; ADR не заводится: дерево и Registry откатываются записью в `CHANGELOG.md`, компромисс
  опроса — ADR-0009, условие читателя дополнено там же.

[ADR-0009](../../../docs/adr/0009-projections-read-event-store.md)

## Comments

- 2026-09-13 — из тикета [«Проекции: источник событий, чекпоинт, порядок»](08-grilling-projections.md): у каждой
  проекции свой последовательный читатель; пачка — транзакция `DAO` под `pg_try_advisory_xact_lock(имя)`, так что
  читатели стартуют на всех нодах без singleton-конфига; сигнал — опрос с adaptive backoff + `wake` после commit
  `append` через `AfterCommit` (одна VM); ошибка на событии — retry с backoff `retry_min_ms` → `retry_max_ms` без
  предела и без пропуска.
- 2026-09-13 — из тикета [«Процесс агрегата»](14-grilling-aggregate-process.md): образец дерева на модуль — `use` у
  потребителя генерирует `child_spec/1`, потребитель ставит модуль в своё дерево; опции старта через
  `Core.Helper.StartOpts`; `enabled: false` → `:ignore`, `info` и отметка в `:persistent_term`, по которой вызов идёт в
  вызывающем процессе; тест самого процесса — `start_supervised`, `async: false`.
- 2026-09-13 — факты: в `lib` нет ни одного супервизора и `:ignore` — дерево и `enabled` outbox собирает потребитель;
  `Core.Workers.PromEx` проверяет `watch_list` только `Process.whereis(atom)`; `Poller.wake/1` адресует процессы по
  именам из конфига; в транзакции с назначенным xid `pg_snapshot_xmin` = свой xid (проверено на `core_test`) — читатель
  `xid < pg_snapshot_xmin` не видит событий своей транзакции, в sandbox — событий теста.
- 2026-09-13 — раунд 1:
  - дерево — библиотечный `Core.Es.Projection.Supervisor`: потребитель ставит `{Core.Es.Projection.Supervisor,
    projections: [A, B], …}`; внутри `rest_for_one`: `Registry` для `wake` → `one_for_one` читателей
    `Core.Es.Projection.Reader`, по одному на проекцию, имя процесса — модуль проекции; на старте `StartOpts`: модуль —
    `use Core.Es.Projection`, `name:` без дублей, иначе `ArgumentError`; список — в коде дерева, не в config;
    `child_spec` на проекцию (как у процесса агрегата) и супервизор у приложения (как у outbox) отвергнуты — дубль
    `name:` виден только там, где весь список;
  - цикл: `:processed` → `schedule(0)` и сброс backoff'ов; `:idle` / `:locked` → `idle_min_ms` ×2 до
    `poll_interval_ms`; `:retry` (исключение, exit, недоступная БД) → `retry_min_ms` ×2 до `retry_max_ms` всегда, даже
    при `wake`; `wake` в ожидании idle-таймера — цикл сразу без сброса счётчика; `wake` во время цикла при `:idle` /
    `:locked` → `schedule(0)`; `flush_wakes` в начале и конце цикла; первый тик — таймер `idle_min_ms` из `init/1`;
    `:idle` после `wake` штатен — событие видно только ниже `pg_snapshot_xmin`; фиксированный опрос без idle-backoff
    отвергнут;
  - остановка — `trap_exit`, `terminate/2` только логирует; `shutdown:` дефолт 30 000 мс, опция; отдельного таймаута
    транзакции пачки нет; цена — последовательная остановка, худший случай N × `shutdown`;
  - синхронный прогон — `Core.Es.Projection.run_once(projection)` → `:processed | :idle | :locked | {:error,
    Error.t()}`: одна пачка в вызывающем процессе, цикл процесса зовёт её же; условие читателя
    `xid < pg_snapshot_xmin(…) OR xid = pg_current_xact_id_if_assigned()` — в проде у транзакции пачки своих событий
    нет, в sandbox видны события теста; внутри `Transact.run` — `raise`; тест с прогоном проекции — `async: false`;
    хелпер в обход читателя и тесты без sandbox отвергнуты;
  - retry: процесс жив, `raise` / `exit` / `throw` пачки ловятся; `warning` на попытку с `projection=`, `position=`,
    `event_id=`, `attempt=` и причиной; попытка, начало и код ошибки — в state и telemetry цикла; `await` ждёт до
    таймаута без досрочной ошибки; колонки `retry_since` / `last_error` в `es_checkpoints` отвергнуты.
- 2026-09-13 — раунд 2:
  - `wake` — `Core.Es.Projection.Registry` (`keys: :duplicate`) в супервизоре проекций: читатель в `init/1`
    регистрируется под типами агрегатов из `events:`, `Core.Es.Store.append` в `AfterCommit` — `Registry.dispatch` по
    типам пачки; Registry не запущен — `:ok`; второй супервизор на ноде — отказ старта по имени Registry; имена из
    конфига (список в двух местах) и `wake` всех читателей отвергнуты; исключение Registry из нормы «имя, по которому
    будят, — из конфига» — в своды;
  - `enabled:` — обязательная опция без дефолта: `false` → `:ignore` + `info`, `projections: []` → `:ignore` + `info`
    «пропущен: нет проекций»; отметки в `:persistent_term` нет; `disabled: [имена]` не сейчас, добавляется без поломки;
    у процесса агрегата `enabled:` — так же обязательна; цена — нода с `enabled: false` не будит, задержка до
    `poll_interval_ms` читателя другой ноды;
  - опции — общие на супервизоре через `StartOpts`, библиотека config и env не читает: `batch_size` 100, `idle_min_ms`
    50, `poll_interval_ms` 1 000, `retry_min_ms` 1 000, `retry_max_ms` 30 000, `shutdown` 30 000; env — в `runtime.exs`
    потребителя, свод рекомендует `ES_PROJECTIONS_*` (длительности — `Core.DurationParser`); переопределение на
    проекцию добавляется без поломки; ключ `config :core, Core.Es.Projection` отвергнут;
  - `watch_list` — каждый читатель под именем модуля проекции, `component: "es_projection:<name>"`, `required:` =
    `enabled`; хелпер `Core.Es.Projection.Supervisor.watch_list(projections)`; только супервизор отвергнут;
  - `CONTEXT.md` не меняется: «читатель» — деталь проекции, слово занято `Mq.ReaderReliable`; ADR не заводится.
- 2026-09-13 — из тикета [«Пересборка проекций»](17-grilling-projection-rebuild.md) (раунды 1–3, тикет не закрыт):
  `version:` проекции хранится в чекпоинте; старт с начала — `clear/0` и чекпоинт в начало в транзакции пачки; нода с
  чекпоинтом новее своей `version:` пропускает тик, `warning` один раз; цель пересборки — в строке чекпоинта; отдельный
  размер пачки на время пересборки передан сюда.
- 2026-09-13 — из тикета [«Пересборка проекций»](17-grilling-projection-rebuild.md): у пачки два новых исхода —
  (1) строки `es_checkpoints` нет или её версия меньше `version:` проекции → пачка без событий: `clear/0` → чекпоинт в
  начало со своей версией и целью, CAS, `info`; (2) версия строки больше `version:` → пропуск тика, `warning` один раз
  при переходе в пропуск (нужен флаг в state читателя); их место среди `:processed | :idle | :locked` и в backoff —
  здесь. Следствие для `run_once`: в тесте на пустом sandbox первый вызов — старт с начала без событий, событие теста
  видно только со второго. Пересборку ведёт тот же читатель с теми же настройками; отдельный размер пачки на время
  пересборки — здесь. `await` при пересборке сразу отдаёт `:projection_rebuilding`; при retry ждёт, как решено здесь.
- 2026-09-13 — раунд 3:
  - пересборка — тот же `batch_size`, `:processed` → `schedule(0)`; `rebuild_batch_size:` и пауза между пачками
    отвергнуты: длинная пишущая транзакция держит `pg_snapshot_xmin` всех читателей кластера; добавляются без поломки;
  - старт с начала (`clear/0` и чекпоинт в начало) → `:processed`; чекпоинт новее своей `version:` → `:outdated`:
    следующий тик через `poll_interval_ms`, `wake` не ускоряет; как `:idle` отвергнуто — старая нода опрашивала бы
    впустую до конца выкладки; `run_once` → `:processed | :idle | :locked | :outdated | {:error, Error.t()}`.
- 2026-09-13 — туман карты «Наблюдаемость» и «Тестовая поддержка» выведен в тикеты
  [«Наблюдаемость event-sourced агрегата и проекций»](19-grilling-observability.md) и
  [«Тестовая поддержка проекций и процессов»](20-grilling-test-support-projections-processes.md).
- 2026-09-13 — из тикета [«Наблюдаемость event-sourced агрегата и проекций»](19-grilling-observability.md):
  `Core.Workers.PromEx` `required:` не читает — отсутствующий процесс даёт `up=0`; `required:` = `enabled` заменено:
  `Core.Es.Projection.Supervisor.watch_list/1` при `enabled: false` элементы не включает.
- 2026-09-13 — из тикета [«Тестовая поддержка проекций и процессов»](20-grilling-test-support-projections-processes.md):
  пересмотр «отметки в `:persistent_term` нет» — любой старт `Core.Es.Projection.Supervisor` ставит отметку (список
  проекций и опции), `await` без неё или на проекцию не из `projections:` — `raise`; новая опция `await: :poll | :inline`
  (по умолчанию `:poll`, `:inline` при `enabled: true` — `ArgumentError`): при `:inline` `await` прогоняет проекцию до
  `:idle` в вызывающем процессе, иной исход — `raise`; `run_once(projection, opts \\ [])` с `batch_size:`; решение о
  следующем тике читателя — чистая функция `@doc false`.
