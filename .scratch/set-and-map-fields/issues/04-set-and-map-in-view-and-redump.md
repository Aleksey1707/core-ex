# 04: `set:` / `map:` в View и Redump

**What to build:** проекция читает поле-множество и поле-словарь из `jsonb` через Redump и View; struct View
держит `MapSet` / map, а наружу отдаёт ту же форму, что wire. Спека — `.scratch/set-and-map-fields/spec.md`,
решение — ADR-0091.

**Blocked by:** 01, 02

**Status:** resolved

- [x] Redump получает формы множества и словаря; внутренняя форма записи `{:map, %{поле => спека}}` не
      переименовывается.
- [x] Плагин по полям выводит Redump-спеку для `set:` / `map:`.
- [x] `use Core.View` принимает `set:` и `map:`: тип, чтение, вывод — отсортированный список / объект.
- [x] Тесты через `use`: read-путь из jsonb-формы и вывод View.
- [x] `@moduledoc` `Core.View`: виды `set:` / `map:`.
- [x] CHANGELOG: пункт из 01 дополняется.
- [x] `make` зелёный.
