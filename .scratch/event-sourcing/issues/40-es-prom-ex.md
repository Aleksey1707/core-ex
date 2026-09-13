# 40: `Core.Es.PromEx` и алерты проекций

**What to build:** дежурный подключает `Core.Es.PromEx` с `projections:` / `processes:` и видит метрики восстановления
агрегатов, снапшотов, циклов и ожидания проекций, отставание проекции, признаки пересборки и устаревшей ноды, сироты
чекпоинтов и число процессов агрегата; в своде проекций — рекомендованные алерты `EsProjection*` с PromQL.

**Blocked by:** [32: Снапшоты](32-snapshots.md), [35: Дерево проекций](35-projection-supervisor.md),
[36: Read-after-write](36-projection-await.md), [39: Процесс агрегата на id](39-aggregate-process.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Наблюдаемость»

- [ ] Один плагин `Core.Es.PromEx`: repo из `Core.Config`, сбор под `Core.PromEx.Safe`, имена по README «Имена
      метрик».
- [ ] Event-группы — всегда: восстановление и свёртка агрегата, запись снапшота, цикл проекции
      (`cycles.total{projection,result}`, `duration{projection,result}`, `events.total{projection}`,
      `retry.total{projection,error}`), `await`, процесс агрегата (`execute`, `start`, `stop`).
- [ ] Polling проекций — при MFA `projections:` (тот же провайдер отдаёт список `Core.Es.Projection.Supervisor`):
      отставание — `now − at` первого события типов проекции после чекпоинта (`LIMIT 1` на тип по индексу
      `(тип, xid, номер)`, без условия `pg_snapshot_xmin`; нет событий — 0; нет строки чекпоинта — возраст первого
      события истории); gauge `rebuilding{projection}`, `outdated{projection}` (версия строки выше `version:` модуля на
      этой ноде), `checkpoint.orphan{name}` (имени нет в списке ноды).
- [ ] Polling процессов — при MFA `processes:`: `processes{type}` через `DynamicSupervisor.count_children/1`.
- [ ] Тесты по образцу PromEx-плагина outbox: значения polling на подготовленных чекпоинтах и событиях (отставание,
      пересборка, `outdated`, сирота), недоступная БД под `Core.PromEx.Safe`, без MFA — только event-группы.
- [ ] `22-projections.md`, «Эксплуатация»: `EsProjectionRetrying`, `EsProjectionLagging` (при `rebuilding == 0`),
      `EsProjectionRebuildLong`, `EsProjectionOutdated` — имя, PromQL, смысл; пороги — у потребителя; без алертов —
      падение читателей и процессов (`WorkerDown`), сироты чекпоинтов, запись снапшота, `version_mismatch` процесса,
      `await` `:timeout`.
- [ ] README — PromEx `Core.Es.PromEx` с `projections:` / `processes:` и «Имена метрик»; `description` skill
      `observability`; `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
