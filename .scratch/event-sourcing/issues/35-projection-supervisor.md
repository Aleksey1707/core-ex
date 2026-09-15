# 35: Дерево проекций: `Core.Es.Projection.Supervisor`, читатели и `wake` из `append`

**What to build:** разработчик приложения ставит `{Core.Es.Projection.Supervisor, projections: [...], enabled: ...}` в
своё дерево — и на каждой ноде читатели проекций сами обрабатывают новые события: их будит `append` после commit, между
событиями опрашивают хранилище с backoff, на ошибке стоят в retry без пропуска и штатно останавливаются при выкладке.

**Blocked by:** [34: Пересборка проекции](34-projection-rebuild.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Дерево проекций»

- [x] Супервизор `rest_for_one`: `Core.Es.Projection.Registry` (`keys: :duplicate`) → `one_for_one` читателей
      `Core.Es.Projection.Reader`, по одному на проекцию, имя процесса — модуль проекции.
- [x] `StartOpts`: `projections:` и `enabled:` обязательны; дефолты `batch_size` 100, `idle_min_ms` 50,
      `poll_interval_ms` 1 000, `retry_min_ms` 1 000, `retry_max_ms` 30 000, `shutdown` 30 000 (перечень — в
      moduledoc); модуль без `use Core.Es.Projection` или дубль `name:` — `ArgumentError`; второй супервизор на ноде —
      отказ старта. Config и env библиотека не читает.
- [x] `enabled: false` → `:ignore` + `info`; `projections: []` → `:ignore` + `info` «пропущен: нет проекций»; любой
      старт ставит отметку в `:persistent_term` (список проекций и опции).
- [x] Читатель в `init/1` регистрируется в Registry под типами агрегатов из `events:`; первый тик — таймер
      `idle_min_ms`, запросов в `init/1` нет. `Core.Es.Store.append` в `AfterCommit` делает `Registry.dispatch` по
      типам агрегатов пачки; Registry не запущен — `:ok`.
- [x] Цикл: `:processed` → `schedule(0)` и сброс backoff'ов; `:idle` / `:locked` → удвоение от `idle_min_ms` до
      `poll_interval_ms`, `wake` в ожидании — цикл сразу без сброса счётчика, `wake` во время цикла — `schedule(0)`;
      `:retry` (ошибка, исключение, exit, throw, недоступная БД) → удвоение от `retry_min_ms` до `retry_max_ms`, `wake`
      не ускоряет, процесс не рестартует; `:outdated` → `poll_interval_ms`, `wake` не ускоряет; `flush_wakes` в начале
      и в конце цикла.
- [x] Решение о следующем тике — чистая функция `@doc false` с тестом таблицей исходов без процесса.
- [x] `warning` на каждую попытку retry с `projection=`, `position=`, `event_id=`, `attempt=` и причиной; `warning`
      один раз при переходе в `:outdated`; попытка, начало и код ошибки — в state.
- [x] `trap_exit`, `terminate/2` только логирует; `shutdown:` — у child spec читателя.
- [x] Telemetry `[:es, :projection, :cycle]` на каждый цикл, включая `:idle` / `:locked`: `duration`, `events`,
      `attempt`; `projection`, `result`, при `:retry` — `error` (`ns/code` или модуль исключения).
- [x] `Core.Es.Projection.Supervisor.watch_list(projections)` — элемент на читателя под именем модуля проекции,
      `component: "es_projection:<name>"`; при `enabled: false` элементов нет.
- [x] Тесты процесса: `start_supervised` с интервалами 60 000 мс, тики `send(pid, :tick)`, `wake` через
      `Registry.dispatch`, факт цикла — telemetry в pid теста, `refute_receive` — только «`wake` не запустил цикл»;
      `wake` после commit `append`; `:outdated` — вставленная строка чекпоинта с версией выше; `trap_exit` —
      блокирующий `project/1` и остановка посреди пачки; проверки `StartOpts`.
- [x] `17-otp-concurrency.md`: «Имена процессов» — получатели `wake` регистрируются в `Registry` сами; SHOULD —
      следующий тик нового периодического цикла — чистая функция с тестом без процесса; `Core.Es.Projection.Reader` в
      таблице `trap_exit`; элемент `watch_list` не включается при выключенном поддереве вместо `required:`.
      `22-projections.md` — «Дерево» (один супервизор со всем списком). README — supervision и env `ES_PROJECTIONS_*`
      (длительности — `Core.DurationParser`). `description` skill `otp-concurrency`. `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - `watch_list/1` принимает опции дерева (`projections:` и `enabled:`), а не голый список модулей: иначе ей неоткуда
    знать `enabled`. Опции проверяются так же, как в `start_link/1`; README и своды предлагают собирать их одной
    функцией приложения (`MyApp.Projections.opts/0`) для дерева и `watch_list`;
  - `Core.Es.Projection.Registry` — модуль (`child_spec/1`, `@doc false` `register/1` и `wake/1`), а не только имя:
    `Es.Store` зовёт его, не ссылаясь на читателя, и цикла `Store → Reader → Batch → Store` в `xref` нет;
  - `Batch.run/3` отдаёт исход читателю богаче: `{:processed, число событий}` и `{:error, error, %{position,
    event_id}}` — позиция чекпоинта до пачки (как `core.es.checkpoint.from` span'а) и событие отказа; `run_once/2`
    сводит его к прежнему контракту. Исключение вне колбэков, exit и throw минуют `{:error, _}` пачки — у них
    `position=nil event_id=nil`, `error` — модуль исключения, `"exit"`, `"throw"`;
  - серию повторов заканчивает любой исход, кроме `:retry` и `:locked`: `retry_ms`, попытка, начало и код ошибки
    сбрасываются не только на `:processed` — иначе сбой через час после восстановления начинался бы сразу с
    `retry_max_ms`. `:locked` серию не заканчивает: пачку держит другая нода, об отказе это ничего не говорит.
    `:idle` / `:locked` и `:outdated` `idle_ms` не трогают;
  - `wake` принимается в ожидании после `:idle` / `:locked` и до первого тика; после `:processed` игнорируется —
    тик с нулевой задержкой уже в очереди;
  - отметка в `:persistent_term` ставится при `:ignore` и после успешного `Supervisor.start_link`: отказ второго
    супервизора отметку первого не перетирает; чтение — `@doc false` `mark/0` (для 36);
  - `info` «запущен» — и на успешном старте (`17-otp-concurrency.md`: «запущен» / «отключён» / «пропущен»);
    `terminate/2` читателя — `info` «читатель остановлен»;
  - `Core.Helper.StartOpts` — обязательные `list!/3` и `boolean!/3`; неизвестные ключи опций не проверяются, как у
    остальных процессов на `StartOpts`;
  - сверх пунктов: `@spec` у колбэков `GenServer` / `Supervisor`; строки карт `00-index.md` и `AGENTS.md`,
    `description` skill `projections`; moduledoc `Core.Es.Projection` и `Core.Es.Store` — про дерево и `wake`.
- 2026-09-14 — по ревью:
  - `:locked` не заканчивает серию повторов (см. выше); telemetry `attempt` — только при `:retry`;
  - лишние `:tick` вычерпываются в начале цикла: таймер, сработавший до отмены по `wake`, запустил бы повтор мимо
    задержки;
  - метка `error` исключения колбэка — модуль исключения из `detail`, а не `es/projection_raised`;
  - `Registry.wake/1` — `rescue ArgumentError` вместо `whereis` → `dispatch` без гонки; `17-otp-concurrency.md`,
    «`init/1`» — регистрация в локальном `Registry` в перечне допустимого; тест снимает отметку дерева в `on_exit`,
    а остановку посреди пачки ловит трассировкой приёма, а не опросом mailbox;
  - оставлено: exit и throw в `project/1` минуют `{:error, _}` пачки — `position=nil event_id=nil` (ловить их в
    транзакции пачки — смена контракта `run_once/2` из 33); начало серии — только в state, как в чеклисте;
    `@doc false` у `Registry.register/1`, `wake/1` и `mark/0` — внутренний API между модулями, как
    `Es.Store.list_after/4`; хелпер `wake` теста зовёт `Registry.dispatch` напрямую — так тест проверяет ключи
    регистрации.
