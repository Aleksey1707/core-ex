# 35: Дерево проекций: `Core.Es.Projection.Supervisor`, читатели и `wake` из `append`

**What to build:** разработчик приложения ставит `{Core.Es.Projection.Supervisor, projections: [...], enabled: ...}` в
своё дерево — и на каждой ноде читатели проекций сами обрабатывают новые события: их будит `append` после commit, между
событиями опрашивают хранилище с backoff, на ошибке стоят в retry без пропуска и штатно останавливаются при выкладке.

**Blocked by:** [34: Пересборка проекции](34-projection-rebuild.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Дерево проекций»

- [ ] Супервизор `rest_for_one`: `Core.Es.Projection.Registry` (`keys: :duplicate`) → `one_for_one` читателей
      `Core.Es.Projection.Reader`, по одному на проекцию, имя процесса — модуль проекции.
- [ ] `StartOpts`: `projections:` и `enabled:` обязательны; дефолты `batch_size` 100, `idle_min_ms` 50,
      `poll_interval_ms` 1 000, `retry_min_ms` 1 000, `retry_max_ms` 30 000, `shutdown` 30 000 (перечень — в
      moduledoc); модуль без `use Core.Es.Projection` или дубль `name:` — `ArgumentError`; второй супервизор на ноде —
      отказ старта. Config и env библиотека не читает.
- [ ] `enabled: false` → `:ignore` + `info`; `projections: []` → `:ignore` + `info` «пропущен: нет проекций»; любой
      старт ставит отметку в `:persistent_term` (список проекций и опции).
- [ ] Читатель в `init/1` регистрируется в Registry под типами агрегатов из `events:`; первый тик — таймер
      `idle_min_ms`, запросов в `init/1` нет. `Core.Es.Store.append` в `AfterCommit` делает `Registry.dispatch` по
      типам агрегатов пачки; Registry не запущен — `:ok`.
- [ ] Цикл: `:processed` → `schedule(0)` и сброс backoff'ов; `:idle` / `:locked` → удвоение от `idle_min_ms` до
      `poll_interval_ms`, `wake` в ожидании — цикл сразу без сброса счётчика, `wake` во время цикла — `schedule(0)`;
      `:retry` (ошибка, исключение, exit, throw, недоступная БД) → удвоение от `retry_min_ms` до `retry_max_ms`, `wake`
      не ускоряет, процесс не рестартует; `:outdated` → `poll_interval_ms`, `wake` не ускоряет; `flush_wakes` в начале
      и в конце цикла.
- [ ] Решение о следующем тике — чистая функция `@doc false` с тестом таблицей исходов без процесса.
- [ ] `warning` на каждую попытку retry с `projection=`, `position=`, `event_id=`, `attempt=` и причиной; `warning`
      один раз при переходе в `:outdated`; попытка, начало и код ошибки — в state.
- [ ] `trap_exit`, `terminate/2` только логирует; `shutdown:` — у child spec читателя.
- [ ] Telemetry `[:es, :projection, :cycle]` на каждый цикл, включая `:idle` / `:locked`: `duration`, `events`,
      `attempt`; `projection`, `result`, при `:retry` — `error` (`ns/code` или модуль исключения).
- [ ] `Core.Es.Projection.Supervisor.watch_list(projections)` — элемент на читателя под именем модуля проекции,
      `component: "es_projection:<name>"`; при `enabled: false` элементов нет.
- [ ] Тесты процесса: `start_supervised` с интервалами 60 000 мс, тики `send(pid, :tick)`, `wake` через
      `Registry.dispatch`, факт цикла — telemetry в pid теста, `refute_receive` — только «`wake` не запустил цикл»;
      `wake` после commit `append`; `:outdated` — вставленная строка чекпоинта с версией выше; `trap_exit` —
      блокирующий `project/1` и остановка посреди пачки; проверки `StartOpts`.
- [ ] `17-otp-concurrency.md`: «Имена процессов» — получатели `wake` регистрируются в `Registry` сами; SHOULD —
      следующий тик нового периодического цикла — чистая функция с тестом без процесса; `Core.Es.Projection.Reader` в
      таблице `trap_exit`; элемент `watch_list` не включается при выключенном поддереве вместо `required:`.
      `22-projections.md` — «Дерево» (один супервизор со всем списком). README — supervision и env `ES_PROJECTIONS_*`
      (длительности — `Core.DurationParser`). `description` skill `otp-concurrency`. `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
