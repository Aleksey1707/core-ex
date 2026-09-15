# 40: `Core.Es.PromEx` и алерты проекций

**What to build:** дежурный подключает `Core.Es.PromEx` с `projections:` / `processes:` и видит метрики восстановления
агрегатов, снапшотов, циклов и ожидания проекций, отставание проекции, признаки пересборки и устаревшей ноды, сироты
чекпоинтов и число процессов агрегата; в своде проекций — рекомендованные алерты `EsProjection*` с PromQL.

**Blocked by:** [32: Снапшоты](32-snapshots.md), [35: Дерево проекций](35-projection-supervisor.md),
[36: Read-after-write](36-projection-await.md), [39: Процесс агрегата на id](39-aggregate-process.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Наблюдаемость»

- [x] Один плагин `Core.Es.PromEx`: repo из `Core.Config`, сбор под `Core.PromEx.Safe`, имена по README «Имена
      метрик».
- [x] Event-группы — всегда: восстановление и свёртка агрегата, запись снапшота, цикл проекции
      (`cycles.total{projection,result}`, `duration{projection,result}`, `events.total{projection}`,
      `retry.total{projection,error}`), `await`, процесс агрегата (`execute`, `start`, `stop`).
- [x] Polling проекций — при MFA `projections:` (тот же провайдер отдаёт список `Core.Es.Projection.Supervisor`):
      отставание — `now − at` первого события типов проекции после чекпоинта (`LIMIT 1` на тип по индексу
      `(тип, xid, номер)`, без условия `pg_snapshot_xmin`; нет событий — 0; нет строки чекпоинта — возраст первого
      события истории); gauge `rebuilding{projection}`, `outdated{projection}` (версия строки выше `version:` модуля на
      этой ноде), `checkpoint.orphan{name}` (имени нет в списке ноды).
- [x] Polling процессов — при MFA `processes:`: `processes{type}` через `DynamicSupervisor.count_children/1`.
- [x] Тесты по образцу PromEx-плагина outbox: значения polling на подготовленных чекпоинтах и событиях (отставание,
      пересборка, `outdated`, сирота), недоступная БД под `Core.PromEx.Safe`, без MFA — только event-группы.
- [x] `22-projections.md`, «Эксплуатация»: `EsProjectionRetrying`, `EsProjectionLagging` (при `rebuilding == 0`),
      `EsProjectionRebuildLong`, `EsProjectionOutdated` — имя, PromQL, смысл; пороги — у потребителя; без алертов —
      падение читателей и процессов (`WorkerDown`), сироты чекпоинтов, запись снапшота, `version_mismatch` процесса,
      `await` `:timeout`.
- [x] README — PromEx `Core.Es.PromEx` с `projections:` / `processes:` и «Имена метрик»; `description` skill
      `observability`; `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - `projections:` — MFA-провайдер **опций** дерева (`MyApp.Projections.opts/0`, тот же, что у элемента дерева и
    `watch_list/1`), плагин берёт из них `projections:`; `processes:` — MFA со списком модулей
    `use Core.Es.Aggregate.Process` (допущение, риск низкий: «тот же провайдер» и «одной функцией приложения» в
    `22-projections.md`, «Дерево»);
  - имена — `PromEx.metric_prefix(otp_app, :es)` ++ `projection.cycles.total`, `projection.duration.<unit>`,
    `projection.events.total`, `projection.retry.total` (`keep` по `result: :retry`), `projection.await.*`,
    `aggregate.load.*`, `aggregate.fold.events` (распределение длины хвоста), `snapshot.write.*`,
    `aggregate.process.execute.*` (очередь — только `mode: :process`), `aggregate.process.start|stop.total`; polling —
    `projection.lag.seconds`, `projection.rebuilding`, `projection.outdated`, `checkpoint.orphan`,
    `aggregate.processes`;
  - SQL — на `Core.Config.dao/0`: строки чекпоинтов одним запросом (`Checkpoint.list/1`), первое событие после
    позиции — запрос на тип (`Es.Store.oldest_at_after/3`, `LIMIT 1` через `after_position/2`, как `list_after`);
    возраст — `DateTime.diff` на ноде, как `oldest_age_seconds` outbox, `now` — аргументом `execute_projection_metrics/2`;
  - `checkpoint.orphan` — на каждую строку `es_checkpoints`, 0 для имён из списка: имя, переставшее быть сиротой, не
    застывает на 1;
  - «пересборка» — одна функция `Checkpoint.rebuilding?/2` для метрики и `await` (`Await.progress/3` переведён на неё без
    смены исходов); `outdated?/2` рядом;
  - `processes{type}` — `__es_aggregate_process__/0` из `use` отдаёт имя `DynamicSupervisor` и тип; дерево не запущено
    — 0; тест считает ребёнка, поставленного под `DynamicSupervisor` напрямую, без команды в БД;
  - недоступная БД в тесте — `use Ecto.Repo` без старта пула, подменённый в `:dao`.
- 2026-09-14 — по ревью:
  - тест отставания — от зафиксированного `@now`, точные значения (`19-testing.md`, «Время»);
  - версия строки ниже `version:` — отставание от начала истории: пачка этого кода начнёт с начала, и при пересборке
    отставание убывает с первого опроса; тест;
  - `Checkpoint.list/1` — список пар, а не карта; `21-observability.md` — отсылка к `Core.Es.PromEx` без нормы;
    «Эксплуатация» — «без алертов» нормой SHOULD NOT без разбора причин, «Область» свода, смысл `EsProjectionOutdated` без
    «пропускает пачки» (нода с `enabled: false` пачек не гоняет); README — серия сироты до рестарта ноды;
  - оставлено: `Config.dao()` вместо `repo:` проекции — буквально по спеке и в moduledoc; проверка формы опций
    провайдера — у соседних плагинов её нет, сбой виден `warning` `Core.PromEx.Safe`; один `Safe` на все проекции —
    их запросы идут в одну БД; ветвление по версии в `Batch` — четыре исхода, хелперы его не упрощают; две
    одинаково устроенные poll-группы — как в `Core.Mq.PromEx`; `Map.keys(declaration.streams)` — до этой правки.
