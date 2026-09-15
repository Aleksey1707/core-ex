# 02: Приведение `lib/**` к модели двух уровней

**What to build:** 28 модулей `lib/**`, где публичная функция идёт после приватных, получают маркеры блоков с
именами; приватные, вызываемые более чем из одного блока, уезжают в хвостовой `# ===== общее =====`.

**Blocked by:** [01: Свод и ADR](01-rules-and-adr.md)

**Status:** done

**Spec:** [Разделители внутри модуля](../spec.md)

- [x] Файлы с возвратом `defp` → `def` на уровне модуля (в скобках — число возвратов, счёт грубый, каждый файл
      сверяется глазами): `es/store.ex` (4); `repo/pg/schema.ex`, `repo/pg.ex`, `es/prom_ex.ex`, `es/projection.ex`,
      `es/event_compat_case.ex`, `es/aggregate/repo/pg.ex`, `es/aggregate/process.ex` (по 3); `view.ex`,
      `repo/sc.ex`, `prim.ex`, `otel/es.ex`, `es/projection/supervisor.ex`, `es/projection/checkpoint.ex`,
      `es/projection_case.ex`, `es/aggregate/repo/pg/snapshot.ex`, `es/aggregate/process/server.ex` (по 2);
      `security/secret.ex`, `repo/pg/state_stored.ex`, `outbox.ex`, `es/projection/reader.ex`, `es/outbox.ex`,
      `es/event/codec.ex`, `es/aggregate/process/execution.ex`, `es/aggregate.ex`, `error.ex`, `enum.ex`,
      `codec/facade.ex` (по 1).
- [x] `codec.ex` и `codec/redump.ex` уже размечены — сверить с итоговой формой и порогом, не переделывать.
- [x] Каждому блоку — имя по правилу: русское, кроме терминов кода; имя называет тему блока, а не «остальное» и не
      «прочее».
- [x] Приватные, вызываемые более чем из одного блока (~37), — в хвостовой `# ===== общее =====`. Известные:
      `repo/sc.ex` `alive?`; `es/store.ex` `visible`, `positioned`, `after_position`; `es/prom_ex.ex`
      `metric_prefix`, `plural`, `tag_values`; `es/aggregate/repo/pg.ex` `version_mismatch`, `load`, `load_stream`,
      `mismatch_detail`, `write`; `es/projection/reader.ex` `cancel_timer`, `flush_wakes`, `flush_ticks`,
      `schedule`; `es/projection.ex` `outcome`; `es/projection/checkpoint.ex` `position`;
      `es/projection/supervisor.ex` `options!`, `name`, `watch_item`; `es/aggregate/process/server.ex` `emit`.
      Список неполный — пересчитать после разметки блоков.
- [x] Внутри блока сохраняется правило понижения: публичные, `# ---`, приватные под своими вызывающими.
- [x] Внутри `quote` маркеры не ставятся; вложенный `defmodule` размечается самостоятельно, со своим счётом блоков.
- [x] `make` зелёный: `format-check`, `compile`, `credo`, `test`.

## Comments

Счёт «28 файлов» был грубым (grep по `defp` → `def`): по AST возврат на уровне модуля есть в 20 файлах (43
возврата). Восемь файлов из списка размечать не потребовалось — возврат у них либо внутри `quote`, либо на границе
самостоятельной единицы:

- `repo/pg/schema.ex`, `repo/pg/state_stored.ex`, `view.ex`, `outbox.ex`, `es/outbox.ex`, `es/event/codec.ex` —
  возврат целиком внутри `quote` (маркеры там MUST NOT);
- `error.ex`, `security/secret.ex` — «возврат» упирается в `defimpl`, а это отдельная единица, как вложенный
  `defmodule`.

В хвостовой `общее` уехало 19 приватных в восьми файлах (оценка была ~37): 12 зовутся более чем из одного блока,
ещё 7 — их сателлиты, которые по правилу понижения стоят под своим вызывающим уже внутри `общее`. Список «Известные»
в тикете сократился, потому что блоки собрались по смыслу, и вызовы перестали быть кросс-блочными:

- `es/store.ex` — `list_after` / `last_position` / `last_stream_position` / `oldest_at_after` сведены в блок «чтение
  по позиции» (имена блоков повторяют разделы `@moduledoc`), поэтому `visible`, `after_position`, `positioned`
  остались в нём;
- `es/aggregate/repo/pg.ex` — `get` / `get_many` / `refresh` сведены в «чтение», `append` ушёл в «запись»; кросс-
  блочным остался только `version_mismatch`;
- `es/projection/reader.ex` — `schedule` / `cancel_timer` / `flush_wakes` / `flush_ticks` вернулись в блок «цикл»,
  откуда и зовутся;
- `es/prom_ex.ex` — `plural` и `tag_values` подняты в «метрики событий», кросс-блочен только `metric_prefix`;
- `es/projection.ex` `outcome` и `es/projection/checkpoint.ex` `position` кросс-блочными и не были;
- `es/projection/supervisor.ex` — `start_link` / `init` / `watch_list` / `mark` оказались одним блоком, поэтому
  `options!`, `name`, `watch_item` остались приватными этого блока, а `# =====` модулю не нужен вовсе.

Перестановка публичных определений — часть работы там, где без неё имя блока называло бы «остальное»:
`es/store.ex`, `es/aggregate/repo/pg.ex`, `es/projection/supervisor.ex`, `es/projection/checkpoint.ex`,
`es/projection/reader.ex`, `repo/pg.ex`, `prim.ex`, `enum.ex`, `es/aggregate/process.ex`. Содержимое кода не
менялось: отсортированные непустые строки без маркеров совпадают до и после во всех файлах.

Попутно поправлена форма маркеров вне списка: убран `# ---` внутри `quote` (`es/event/codec.ex`) и `# ---` на
границе `defp` → `defp`, где перехода нет (`cache/prom_ex.ex`, `outbox/prom_ex.ex`).
