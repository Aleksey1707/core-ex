# Наблюдаемость event-sourced агрегата и проекций

Type: grilling
Status: resolved
Blocked by: 10, 14, 17, 18
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Какие сигналы даёт event sourcing в `:core` и где живёт каждый — telemetry + PromEx, span `Core.Otel` или лог
(`21-observability.md`):

- восстановление агрегата (`get` / `get_many` / `refresh`): span или только telemetry; тип агрегата, длина свёрнутого
  хвоста, снапшот найден / не найден / отвергнут;
- читатель проекции: событие telemetry цикла (исход `:processed` / `:idle` / `:locked` / `:retry` / `:outdated`,
  размер пачки, попытка retry), span на пачку или нет; лаг по позиции `(xid, номер)` и по `at` — чем меряется и кто его
  опрашивает; прогресс пересборки (чекпоинт / цель); строка-сирота `es_checkpoints` удалённой проекции;
- алерты: проекция в retry, в том числе на теге, неизвестном кодеку; нода в `:outdated`; лаг проекции;
- процесс агрегата: span команды, ожидание в очереди, повторы после конфликта, число процессов, перенос трейса; место
  `Agg.Process` в `watch_list`, который видит только локально зарегистрированный атом;
- один PromEx-плагин на event sourcing или по компоненту.

## Answer

- **Трейсы.** Контекст трейса в `es_events` не хранится: хранилище вечное, физического удаления потоков нет, baggage
  пропагатора лёг бы туда навсегда, ссылки пересборки вели бы на истёкшие трейсы; связь проекции с командой — `event_id`.
  Словарь `Core.Otel.Es`, все span'ы `kind: :internal`:
  - `execute(type, aggregate_id, command, fun)` — `"execute <тип>"` на call site `Agg.Process.execute` у вызывающего,
    при `enabled: false` тот же: ожидание в очереди и исполнение; `core.es.aggregate.type` / `.id`, `core.es.command`,
    `core.es.execute.mode`, `core.es.retries`, span event `dequeued`;
  - `project(projection_name, version, fun)` — корневой `"project <имя>"` только на пачку с работой (события или старт с
    начала): `project/1` / `clear/0` и CAS; `core.es.projection.name` / `.version` / `.reset`,
    `core.es.batch.event_count`, `core.es.checkpoint.from` / `.to` (`"<xid>/<номер>"`); ошибка — `core.es.event.id` и
    `record_error/1`; у `:idle` / `:locked` / `:outdated` span'а нет;
  - `await(projection_name, type, aggregate_id, fun)` — `"await <имя>"`; `:projection_timeout` /
    `:projection_rebuilding` — `record_error/1`;
  - исключение пачки для span'а — прикладная `%Error{}` с именем модуля исключения в `detail`, без текста (`Error.wrap/2`
    принимает только `%Error{}`); текст — в `warning`, связанном с трейсом через `trace_id`;
  - восстановление агрегата (`get` / `get_many` / `refresh`) span'а не имеет, как `Repo.Pg`.
- **Telemetry** (`Core.Telemetry.event/1`):
  - `[:es, :aggregate, :load]` на вызов — `duration`, `streams`, `events`, `snapshot_hit` / `snapshot_miss` /
    `snapshot_rejected`; `type`, `op: :get | :get_many | :refresh`, `result: :ok | :version_mismatch`;
    `[:es, :aggregate, :fold]` на поток — `events`; `type`, `snapshot: :hit | :miss | :rejected | :off`;
    `[:es, :snapshot, :write]` — `duration`, `rows`; `type`, `result: :ok | :error`;
  - `[:es, :projection, :cycle]` на каждый цикл, включая `:idle` / `:locked`, — `duration`, `events`, `attempt`;
    `projection`, `result`, при `:retry` — `error` (`ns/code` или модуль исключения); gauge попытки нет;
    `[:es, :projection, :await]` — `duration`; `projection`, `result: :ok | :timeout | :rebuilding`;
  - `[:es, :aggregate, :process, :execute]` у вызывающего — `duration`, `queue`, `retries`; `type`,
    `mode: :process | :inline`, `result: :ok | :version_mismatch | :error | :exit`; `:start` и `:stop` с
    `reason: :idle | :error`; код доменной ошибки в теги не идёт.
- **Отставание проекции** — polling: `now − at` первого события типов проекции после чекпоинта (`LIMIT 1` на тип по
  индексу `(тип, xid, номер)`), без условия `pg_snapshot_xmin`; нет событий — 0, нет строки чекпоинта — возраст первого
  события истории; одинаково на нодах; при пересборке убывает — это и прогресс. Gauge по `es_checkpoints` и списку ноды:
  `rebuilding{projection}`, `outdated{projection}` (на ноде), `checkpoint.orphan{name}`. Число процессов —
  `processes{type}` через `DynamicSupervisor.count_children/1`.
- **Плагин** — один `Core.Es.PromEx`: event-группы всегда; polling проекций — с MFA `projections:` (тот же провайдер
  отдаёт список `Core.Es.Projection.Supervisor`), процессов — с MFA `processes:`; repo из `Core.Config`, сбор под
  `Core.PromEx.Safe`.
- **`watch_list`** — у `Agg.Process` только верхний супервизор под атомом модуля,
  `component: "es_aggregate_process:<тип>"`, хелпер генерирует `use`. `Core.Workers.PromEx` `required:` не читает:
  хелперы проекций и процесса при `enabled: false` элемент не включают (пересмотр
  [«OTP-дерево асинхронных проекций»](18-grilling-projection-process-tree.md)).
- **Логи** — повтор после конфликта в процессе агрегата — `debug`, исчерпание `retries:` — `warning`
  `type= aggregate_id= retries=`; старт и уход по idle — `debug`.
- **Алерты** — таблица в `21-observability.md` (имя, PromQL, смысл), пороги у потребителя: `EsProjectionRetrying`,
  `EsProjectionLagging` (при `rebuilding == 0`), `EsProjectionRebuildLong`, `EsProjectionOutdated`. Без алертов: падение
  читателей и процессов (`WorkerDown`), сироты чекпоинтов, запись снапшота, `version_mismatch` процесса, `await`
  `:timeout`.
- Не проверено на нагрузке: polling отставания — проекции × типы × ноды раз в `poll_rate`; объём `:fold` на `get_many`
  и `:cycle` на холостых циклах.
- `CONTEXT.md` — термин «Отставание проекции». ADR не заводится: `headers` в `es_events` добавляются позже
  nullable-колонкой без потерь, остальное откатывается без миграции данных.

## Comments

- 2026-09-13 — из тикета [«OTP-дерево асинхронных проекций»](18-grilling-projection-process-tree.md): исход цикла
  читателя и попытка retry — в state и telemetry цикла, имена событий не выбраны; `warning` на каждую попытку retry;
  `watch_list` читателей решён — каждый под именем модуля проекции, `component: "es_projection:<name>"`, хелпер
  `Core.Es.Projection.Supervisor.watch_list/1`; `Core.Workers.PromEx` проверяет только `Process.whereis(atom)`.
- 2026-09-13 — из тикета [«Пересборка проекций»](17-grilling-projection-rebuild.md): сброс — `info`
  `projection= from_version= to_version=`, достижение цели — `info`, переход в пропуск тиков — `warning` один раз;
  признак «новая проекция догнала» — `info` и метрика прогресса и лага, решаемая здесь.
- 2026-09-13 — факты: у `Repo.Pg` и `Transact.run` нет telemetry и спанов; имена событий — `Core.Telemetry.event/1`
  (`telemetry_prefix` потребителя), образец цикла — `[:outbox, :poller, :cycle]` с `duration` и `result`; лаг outbox —
  polling-метрика `queue.oldest_age.seconds` (SQL `min(created_at)`) под `Core.PromEx.Safe`; плагины — по области, списки
  через MFA (`readers:`, `watch:`); `Core.Workers.PromEx` читает из элемента только `component` и `name`, отсутствующий
  процесс — `up=0`; `traceparent` команды лежит только в `headers` строки outbox; файлов правил алертов в репозитории нет.
- 2026-09-13 — раунд 1:
  - контекст трейса в `es_events` не хранится: хранилище вечное, физического удаления потоков нет, baggage пропагатора
    лёг бы туда навсегда, а ссылки пересборки вели бы на истёкшие трейсы; связь проекции с командой — `event_id` (в
    `warning` retry и атрибутом span'а при ошибке); колонка `headers` и `links` пачки на контексты событий отвергнуты;
  - span пачки проекции — только когда есть работа (события или старт с начала с `clear/0`), корневой, охватывает
    `project/1` / `clear/0` и CAS чекпоинта; `:retry` — `record_error/1` в нём же; у `:idle` / `:locked` / `:outdated`
    span'а нет; пересборка — те же span'ы, объём режет сэмплер; без span'а и span на событие отвергнуты; словарь — новый
    `Core.Otel.<Область>`, `Messaging` не подходит;
  - span команды процесса агрегата — на call site `Agg.Process.execute` у вызывающего: `"execute <тип агрегата>"`,
    `kind: :internal`, охватывает ожидание в очереди и исполнение; число повторов — атрибут `core.*`, взятие команды
    процессом — span event; при `enabled: false` — тот же span; span внутри процесса и без span'а отвергнуты;
  - повтор после конфликта в процессе — `debug`, исчерпание `retries:` — `warning` `type= aggregate_id= retries=`;
    `warning` на каждый повтор отвергнут — конфликт штатен;
  - `watch_list` процесса агрегата — только верхний супервизор под атомом `Agg.Process`,
    `component: "es_aggregate_process:<тип агрегата>"`, хелпер генерирует `use`; процессы на id не отслеживаются;
  - `required:` плагин не читает: хелперы `watch_list` проекций и `Agg.Process` при `enabled: false` элемент не
    включают — вместо `required:` = `enabled` из «OTP-дерево асинхронных проекций»; формулировка `17-otp-concurrency.md`
    про `required:` — в своды; `required:` в `Core.Workers.PromEx` отвергнут — правка контракта выпущенного плагина;
  - алерты — таблица рекомендованных в `21-observability.md` (имя, PromQL, смысл), пороги — у потребителя; файл правил
    в `priv/` и отказ описывать алерты отвергнуты.
- 2026-09-13 — раунд 2:
  - span восстановления агрегата (`get` / `get_many` / `refresh`) нет — как у `Repo.Pg`: SQL — спаны `opentelemetry_ecto`
    потребителя, свёртка — промежуток в span'е usecase или команды процесса и telemetry; span `"load <тип>"` отвергнут,
    добавляется без поломки;
  - telemetry восстановления: `[:es, :aggregate, :load]` на вызов — `duration`, `streams`, `events`, `snapshot_hit`,
    `snapshot_miss`, `snapshot_rejected`; `type`, `op: :get | :get_many | :refresh`, `result: :ok | :version_mismatch`;
    `[:es, :aggregate, :fold]` на поток — `events`; `type`, `snapshot: :hit | :miss | :rejected | :off` — распределение
    длины хвоста для выбора `every:`; запись снапшота — `[:es, :snapshot, :write]`: `duration`, `rows`; `type`,
    `result: :ok | :error`; промах маркера — `:miss`; `raise` на нечитаемом потоке события не шлёт; только событие на
    вызов отвергнуто;
  - `[:es, :projection, :cycle]` на каждый цикл, включая `:idle` / `:locked`: `duration`, `events`, `attempt`;
    `projection`, `result`, при `:retry` — `error` (`ns/code` у `%Error{}`, иначе имя модуля исключения); метрики
    `cycles.total{projection,result}`, `duration{projection,result}`, `events.total{projection}`,
    `retry.total{projection,error}`; gauge попытки нет — lock транзакционный, попытки разнесены по нодам; старт с начала —
    `:processed` с `events: 0`;
  - `await` — telemetry `[:es, :projection, :await]`: `duration`; `projection`, `result: :ok | :timeout | :rebuilding`, и
    span `"await <имя проекции>"` на call site; только telemetry и ничего отвергнуты;
  - отставание проекции — polling-метрика плагина по MFA `projections:`: `now − at` первого события типов проекции после
    чекпоинта (индекс `(тип, xid, номер)`, `LIMIT 1` на тип), без условия `pg_snapshot_xmin` — задержка долгих
    транзакций видна; нет событий — 0, нет строки чекпоинта — возраст первого события истории; одинаково на нодах, алерт
    — `max by (projection)`; при пересборке убывает — это и прогресс; из события цикла и `count(*)` отвергнуты; точность
    — секунды, `at` ставится до commit; термин «Отставание проекции» — `CONTEXT.md`;
  - gauge состояний — polling по `es_checkpoints` и списку ноды: `rebuilding{projection}` (строки нет, версия ниже
    `version:` модуля или чекпоинт < цели), `outdated{projection}` (версия строки выше `version:` модуля на этой ноде),
    `checkpoint.orphan{name}` (имени нет в списке ноды, без рекомендованного алерта — между выкладками 2 и 3 штатна);
    `last_value` из события цикла и одни логи отвергнуты;
  - процесс агрегата: `[:es, :aggregate, :process, :execute]` у вызывающего — `duration`, `queue` (0 при `enabled:
    false`), `retries`; `type`, `mode: :process | :inline`, `result: :ok | :version_mismatch | :error | :exit`;
    `[:es, :aggregate, :process, :start]` и `:stop` с `reason: :idle | :error`; polling `processes{type}` —
    `DynamicSupervisor.count_children/1` по MFA `processes:`; `debug` на старт и уход по idle; код доменной ошибки в теги
    не идёт; только `execute` и без `start` / `stop` отвергнуты.
- 2026-09-13 — раунд 3:
  - словарь `Core.Otel.Es`: `execute(type, aggregate_id, command, fun)`, `project(projection_name, version, fun)`,
    `await(projection_name, type, aggregate_id, fun)`, все `kind: :internal`; атрибуты `core.es.*` — тип и id агрегата,
    команда, режим, повторы; имя, версия, `reset`, число событий и `from` / `to` чекпоинта `"<xid>/<номер>"`;
    `event.id` при ошибке; span event `dequeued`; исключение пачки — прикладная `%Error{}` с именем модуля исключения в
    `detail`, без текста; вариант без `aggregate.id` и `Core.Otel.record_exception/2` отвергнуты;
  - один `Core.Es.PromEx`: event-группы всегда, polling проекций — с MFA `projections:`, процессов — с MFA
    `processes:`, repo из `Core.Config`, `Core.PromEx.Safe`; тот же провайдер `projections:` отдаёт список
    `Core.Es.Projection.Supervisor`; два и три плагина отвергнуты;
  - алерты: `EsProjectionRetrying`, `EsProjectionLagging` (при `rebuilding == 0`), `EsProjectionRebuildLong`,
    `EsProjectionOutdated`; без алертов — падение процессов (`WorkerDown`), сироты, снапшот, `version_mismatch` процесса,
    `await` `:timeout`; наборы из трёх и двух алертов отвергнуты;
  - ADR не заводится.
- 2026-09-13 — из тикета [«Тестовая поддержка проекций и процессов»](20-grilling-test-support-projections-processes.md):
  тест процесса читателя проекции узнаёт о прошедшем цикле по telemetry цикла (хендлер шлёт в pid теста,
  `assert_receive`) — событие на каждый цикл с исходом нужно тестам; у `Core.Es.Projection.Supervisor` появилась опция
  `await: :poll | :inline` — при `:inline` `await` прогоняет проекцию в вызывающем процессе; отметка в
  `:persistent_term` ставится при любом старте супервизора.
