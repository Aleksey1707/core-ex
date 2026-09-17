# 05: Полнота `project/1` при сборке

**What to build:** автор проекции получает предупреждение при сборке, указывающее на строку `use Core.Es.Projection`,
если у `project/1` нет clause для модуля из `events:` или если он опечатался в поле нагрузки, не сузив её паттерном.
Проверка clauses `project/1` в `ProjectionCase` удалена; проверка `clear/0` осталась.

**Blocked by:** 01, 04

**Status:** ready-for-agent

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Функции-проверки полноты», «Тестовые модули»

- [ ] `__before_compile__` проекции генерирует функцию-проверку на каждый модуль `events:` по механике тикета 04, имя —
      `"project/1 принимает <Event>"`.
- [ ] Фикстура: маркеры G1, G3a. Корректная проекция на события двух агрегатов — ноль предупреждений.
- [ ] `Core.Es.ProjectionCase`: тест clause `project/1` на каждый модуль удалён вместе со своими типами; тест `clear/0`
      прежний. Тесты удалённой проверки убраны.
- [ ] `BrokenProjection` и подобные фикстуры core-ex перестроены под оставшуюся проверку `clear/0` без пропуска clause;
      сборка core-ex с `--warnings-as-errors` зелёная.
- [ ] moduledoc `Core.Es.Projection` (проверка при сборке) и `Core.Es.ProjectionCase`.
- [ ] `22-projections.md` и `19-testing.md` обоих ярусов — где полнота `project/1` приписана `ProjectionCase`;
      описание скилла `projections`.
- [ ] `CHANGELOG.md`, «Не выпущено»: пункт проекций / `ProjectionCase` дополнен, «было → стало».
- [ ] `make` зелёный.

Prior art: `.scratch/es-type-safety/prototype/lib.diff` (`projection.ex`, `es_fixture/broken_projection.ex`), раздел
P2 в `RESULTS.md`.
