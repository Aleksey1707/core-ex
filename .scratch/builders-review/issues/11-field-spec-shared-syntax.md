# 11: Общий синтаксис спеки полей для View и плагина

**Status:** needs-triage

**Blocked by:** `.scratch/codec-field/` (оба тикета)

**Сила:** Worth exploring. Это часть (c) кандидата 1, отложенная на этапе проработки (Q1).

**Файлы:** `lib/core/view/opts.ex` (261 строка: `field!`, `kind_key!`, `spec!(:list)`, `check_duplicates!`), грамматика `Core.Codec.Field` (после `.scratch/codec-field/`), `lib/core/labels/check.ex` (`keyword!`), `lib/core/helper/field_check.ex` (57 строк), `lib/core/codec/redump.ex` (`validate!({:prim, _})`).

**Проблема.**
- `View.Opts` и грамматика плагина реализуют одни и те же правила с разной рекурсией: keyword-форма, дубли имён, ровно один kind-ключ, `prim:` / `enum:` / `type:`, `optional:` boolean и не внутри `list:` (текст ошибки одинаковый), `type_values`.
- Проверка повторов ключей написана трижды: во View, в плагине и в Labels.
- `FieldCheck` по deletion test shallow: выносит только листовые проверки.
- Правило «Prim допустим на read-пути» (sensitive, coercible) записано дважды и даёт разные исключения: `View.Opts` бросает `CompileError`, `Redump.validate!` — `ArgumentError`.

**Что изменилось бы.** Один нормализатор синтаксиса, которому каждая декларация задаёт свой набор kind'ов: View — `view` / `form` / `jsonb`, плагин — `entity` / `union` / `default`. Семантику своих kind'ов проверяет сама декларация.

**Выигрыш.** Locality правил и одинаковые ошибки компиляции. Leverage для View, плагина и Labels.

**ADR.** ADR-0056 отверг «общую спеку с Core.View» — по семантике, а не по синтаксису («общие — имена ключей и элементарные проверки»). Формулировку ADR нужно уточнить. ADR-0057 называет имя спеки «общим с `Core.View`», но кодом это не подкреплено.
