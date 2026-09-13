# 36: Read-after-write: `Core.Es.Projection.await` и `await: :inline`

**What to build:** после `:ok` usecase вызывающий ждёт, пока проекция обработает последние события потока агрегата, —
`Core.Es.Projection.await(projection, aggregate, aggregate_id, timeout)` — и показывает read-модель уже с ними. Во время
пересборки ожидание сразу отдаёт `:projection_rebuilding`, а не висит до таймаута. В тестах дерево с `await: :inline`
прогоняет проекцию прямо в вызывающем процессе.

**Blocked by:** [35: Дерево проекций](35-projection-supervisor.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Проекции: объявление, пачка, ожидание,
пересборка», пункт `await`

- [ ] Цель — позиция последнего события потока на момент вызова; пустой поток — `:ok`; чекпоинт ≥ цели — `:ok`.
- [ ] Идёт пересборка (строки нет, её версия ниже `version:` или чекпоинт < цели пересборки) — сразу прикладная
      `:projection_rebuilding`; иначе опрос `es_checkpoints` до таймаута, истечение — прикладная `:projection_timeout`;
      во время retry проекции — ожидание до таймаута.
- [ ] Тип агрегата, на который проекция не подписана, — `FunctionClauseError`; внутри `Transact.run` — `raise`; нет
      отметки дерева — `raise` «дерево проекций не запущено»; проекция не из `projections:` — `raise`.
- [ ] Опция супервизора `await: :poll | :inline`, по умолчанию `:poll`; `:inline` при `enabled: true` —
      `ArgumentError`. При `:inline` `await` прогоняет проекцию до `:idle` в вызывающем процессе с `batch_size` из
      отметки и сверяет чекпоинт; любой другой исход — `raise` с исходом и именем проекции.
- [ ] Span `Core.Otel.Es.await(projection_name, type, aggregate_id, fun)` — `"await <имя>"`, `record_error/1` на
      `:projection_timeout` / `:projection_rebuilding`; telemetry `[:es, :projection, :await]` (`duration`;
      `projection`, `result: :ok | :timeout | :rebuilding`).
- [ ] Тесты: `:inline` в sandbox после записи через репозиторий; `:poll` с запущенным читателем; таймаут; пересборка;
      каждый `raise`; span и telemetry.
- [ ] `12-errors.md` «Источники `%Error{}`» — `:projection_timeout` / `:projection_rebuilding`; `20-agreements.md` —
      `await` MUST NOT внутри `Transact.run`; `19-testing.md` — `await: :inline` в тестовом дереве; `22-projections.md`
      — «Read-after-write»; `21-observability.md` — span `await` на call site. `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
