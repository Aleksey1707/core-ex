# 04: `layout_lint.exs`, цель `make layout-check`, pre-commit

**What to build:** линтер раскладки модуля, шаг сборки и хук pre-commit. Идёт последним: до приведения `lib/**` и
`test/support/**` он бы красил `make`.

**Blocked by:** [01: Свод и ADR](01-rules-and-adr.md), [02: Приведение `lib/**`](02-lib-migration.md),
[03: Приведение `test/support/**`](03-test-support-migration.md)

**Status:** done

**Spec:** [Разделители внутри модуля](../spec.md)

- [x] `scripts/layout_lint.exs` в форме соседей (`rules_lint.exs`, `boundary_lint.exs`): шапка-комментарий с
      назначением и командой запуска, `defmodule LayoutLint` с `@moduledoc false`, `abort/1` со списком нарушений,
      успех — строка с числом проверенных файлов.
- [x] Проверки: (1) переход public → private предварён `# ---`; (2) возврат private → public предварён
      `# ===== <имя> =====`; (3) в модуле с ≥2 блоками размечен первый блок; (4) в модуле с одним блоком
      `# =====` нет; (5) форма — ровно `# ---` и `# ===== <имя> =====`, отступ как у определений модуля, пустая
      строка сверху и снизу; (6) блок без публичных определений допустим один раз и только последним, `# ---`
      внутри него нет.
- [x] Зоны: `lib/**` и `test/support/**` — все проверки; `test/**` вне `support` — только (5); внутри `quote`
      скрипт молчит; вложенный `defmodule` — самостоятельная единица со своим счётом блоков.
- [x] Цель `layout-check` в `Makefile` после `rules-check`, до `format-check`; добавлена в default-цепочку и в её
      комментарий.
- [x] Хук `layout-lint` в `.pre-commit-config.yaml` на том же месте цепочки: `language: system`,
      `require_serial: true`, `pass_filenames: false`; комментарий порядка в начале файла обновлён.
- [x] Строка `Проверяется: make layout-check` в разделе свода; таблица шагов и строка цепочки в
      «Linters & Formatters» (`20-agreements.md`) и «Команды» (`AGENTS.md`, симлинк `CLAUDE.md`) обновлены.
- [x] `make` зелёный целиком.
