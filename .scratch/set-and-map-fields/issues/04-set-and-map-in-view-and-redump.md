# 04: `set:` / `map:` в View и Redump

**What to build:** проекция читает поле-множество и поле-словарь из `jsonb` через Redump и View; struct View
держит `MapSet` / map, а наружу отдаёт ту же форму, что wire. Спека — `.scratch/set-and-map-fields/spec.md`,
решение — ADR-0091.

**Blocked by:** 01, 02

**Status:** ready-for-agent

- [ ] Redump получает формы множества и словаря; внутренняя форма записи `{:map, %{поле => спека}}` не
      переименовывается.
- [ ] Плагин по полям выводит Redump-спеку для `set:` / `map:`.
- [ ] `use Core.View` принимает `set:` и `map:`: тип, чтение, вывод — отсортированный список / объект.
- [ ] Тесты через `use`: read-путь из jsonb-формы и вывод View.
- [ ] `@moduledoc` `Core.View`: виды `set:` / `map:`.
- [ ] CHANGELOG: пункт из 01 дополняется.
- [ ] `make` зелёный.
