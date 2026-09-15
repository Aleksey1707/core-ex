# 36: Read-after-write: `Core.Es.Projection.await` и `await: :inline`

**What to build:** после `:ok` usecase вызывающий ждёт, пока проекция обработает последние события потока агрегата, —
`Core.Es.Projection.await(projection, aggregate, aggregate_id, timeout)` — и показывает read-модель уже с ними. Во время
пересборки ожидание сразу отдаёт `:projection_rebuilding`, а не висит до таймаута. В тестах дерево с `await: :inline`
прогоняет проекцию прямо в вызывающем процессе.

**Blocked by:** [35: Дерево проекций](35-projection-supervisor.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Проекции: объявление, пачка, ожидание,
пересборка», пункт `await`

- [x] Цель — позиция последнего события потока на момент вызова; пустой поток — `:ok`; чекпоинт ≥ цели — `:ok`.
- [x] Идёт пересборка (строки нет, её версия ниже `version:` или чекпоинт < цели пересборки) — сразу прикладная
      `:projection_rebuilding`; иначе опрос `es_checkpoints` до таймаута, истечение — прикладная `:projection_timeout`;
      во время retry проекции — ожидание до таймаута.
- [x] Тип агрегата, на который проекция не подписана, — `FunctionClauseError`; внутри `Transact.run` — `raise`; нет
      отметки дерева — `raise` «дерево проекций не запущено»; проекция не из `projections:` — `raise`.
- [x] Опция супервизора `await: :poll | :inline`, по умолчанию `:poll`; `:inline` при `enabled: true` —
      `ArgumentError`. При `:inline` `await` прогоняет проекцию до `:idle` в вызывающем процессе с `batch_size` из
      отметки и сверяет чекпоинт; любой другой исход — `raise` с исходом и именем проекции.
- [x] Span `Core.Otel.Es.await(projection_name, type, aggregate_id, fun)` — `"await <имя>"`, `record_error/1` на
      `:projection_timeout` / `:projection_rebuilding`; telemetry `[:es, :projection, :await]` (`duration`;
      `projection`, `result: :ok | :timeout | :rebuilding`).
- [x] Тесты: `:inline` в sandbox после записи через репозиторий; `:poll` с запущенным читателем; таймаут; пересборка;
      каждый `raise`; span и telemetry.
- [x] `12-errors.md` «Источники `%Error{}`» — `:projection_timeout` / `:projection_rebuilding`; `20-agreements.md` —
      `await` MUST NOT внутри `Transact.run`; `19-testing.md` — `await: :inline` в тестовом дереве; `22-projections.md`
      — «Read-after-write»; `21-observability.md` — span `await` на call site. `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - `aggregate` — модуль `<Aggregate>` любого вида; тип агрегата — поток проекции, чей кодек `<Aggregate>.Event.Codec`
    (раскладка, которую проекция требует на компиляции). `__es_event_codec__/0` не годится: у state-stored агрегата
    его нет. Потока нет — `FunctionClauseError` перебора потоков без клаузы на пустой список;
  - порядок — как в спеке и решении 17: чекпоинт ≥ цели — `:ok` при любой версии строки и во время пересборки;
    затем строки нет, её версия ниже `version:` или чекпоинт < цели пересборки — пересборка. Строка с версией выше
    `version:` сверяется по позиции;
  - опрос — удвоение интервала от 10 до 100 мс, константы модуля: спека интервал не задаёт, а опции дерева описывают
    цикл читателя (тестовое дерево с 60 000 мс превратило бы любое ожидание в таймаут);
  - тело — `Core.Es.Projection.Await` (как `Batch` у `run_once/2`): `:inline` гоняет `Batch.run/3`, а не `run_once/2`,
    иначе `Projection → Await → Projection` — цикл в `xref`; цель — `@doc false` `Core.Es.Store.last_stream_position/3`
    без условия видимости: ожидание идёт после commit, невидимое пачке событие чекпоинт догонит позже;
  - исключения: внутри транзакции и проекция не из `projections:` — `ArgumentError` (как `run_once/2`); нет отметки
    дерева и исход `:inline` — `RuntimeError`; `:inline`, дошедший до `:idle` с чекпоинтом ниже цели, — тоже
    `RuntimeError` с исходом `{:idle, :behind}`. Проверки идут до span'а и telemetry: `raise` их не шлёт;
  - `timeout` — `non_neg_integer` мс; detail ошибок — `projection`, у таймаута ещё `timeout`; пустой поток при
    `:inline` — `:ok` без прогона;
  - сверх пунктов: README (`config/test.exs` с `await: :inline`), `description` skills `projections`, `testing`,
    `observability`, строки карт `00-index.md` и `AGENTS.md`, moduledoc `Core.Es.Projection.Supervisor`,
    `Core.Es.Store`, `Core.Es.Projection.Checkpoint`, `Core.Otel.Es`.
- 2026-09-14 — по ревью:
  - порядок проверок сначала был изменён — строка старой версии давала пересборку раньше сверки с целью (read-модель
    построена старым кодом, первая пачка новой версии её очистит); это отступление от решения 17, возвращено к спеке
    до решения пользователя;
  - тесты `:inline` на `:locked` и на `{:idle, :behind}` (событие, закоммиченное другим соединением после xid
    транзакции теста); `:ok` при чекпоинте ≥ цели во время пересборки и при строке старой версии;
  - «Read-after-write» в `22-projections.md` ссылается на запрет из `20-agreements.md`, а не повторяет его; норма
    SHOULD NOT без примера снята; «Проверяется» в `19-testing.md`, не проверявшая правило, убрана;
  - `aggregate` — модуль, в котором лежит `<Aggregate>.Event.Codec`: у state-stored фикстуры это `Core.EventFixture`,
    а не struct `StateStoredFixture.Entity`;
  - `Core.Otel.Es.await/4` — в конце модуля под своим разделителем; `listed_mark!` → `tree_mark!`,
    `stream_position` → `last_stream_position`;
  - оставлено: PromEx-метрика `await` — тикет 40; повтор проверки транзакции и guards `Await.run/5` — как у
    `Batch.run/3` и `run_once/2`; `struct()` у `aggregate_id` — как у `page_stream/5`; хелперы тестов скопированы, как
    в `supervisor_test.exs`.
