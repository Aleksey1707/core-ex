# 05: Полнота `project/1` при сборке

**What to build:** автор проекции получает предупреждение при сборке, указывающее на строку `use Core.Es.Projection`,
если у `project/1` нет clause для модуля из `events:` или если он опечатался в поле нагрузки, не сузив её паттерном.
Проверка clauses `project/1` в `ProjectionCase` удалена; проверка `clear/0` осталась.

**Blocked by:** 01, 04

**Status:** resolved

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Функции-проверки полноты», «Тестовые модули»

- [x] `__before_compile__` проекции генерирует функцию-проверку на каждый модуль `events:` по механике тикета 04, имя —
      `"project/1 принимает <Event>"`.
- [x] Фикстура: маркеры G1, G3a. Корректная проекция на события двух агрегатов — ноль предупреждений.
- [x] `Core.Es.ProjectionCase`: тест clause `project/1` на каждый модуль удалён вместе со своими типами; тест `clear/0`
      прежний. Тесты удалённой проверки убраны.
- [x] `BrokenProjection` и подобные фикстуры core-ex перестроены под оставшуюся проверку `clear/0` без пропуска clause;
      сборка core-ex с `--warnings-as-errors` зелёная.
- [x] moduledoc `Core.Es.Projection` (проверка при сборке) и `Core.Es.ProjectionCase`.
- [x] `22-projections.md` и `19-testing.md` обоих ярусов — где полнота `project/1` приписана `ProjectionCase`;
      описание скилла `projections`.
- [x] `CHANGELOG.md`, «Не выпущено»: пункт проекций / `ProjectionCase` дополнен, «было → стало».
- [x] `make` зелёный.

Prior art: `.scratch/es-type-safety/prototype/lib.diff` (`projection.ex`, `es_fixture/broken_projection.ex`), раздел
P2 в `RESULTS.md`.

## Comments

- 2026-09-17 — реализация:
  - `__before_compile__` `use Core.Es.Projection` зовёт `Es.Check.define/5` на каждый модуль `events:` в порядке
    объявления, тело — локальный `project(event)`; строка `use` — атрибут `@es_use_line` из `__using__`. Сообщение —
    `incompatible types given to project/1` с именем-утверждением в `└─`;
  - фикстура: G1 — на `BadProjection` (clause `Opened` сужена `%Payload{}`), G3a — отдельный модуль
    `BadProjectionPayload`, на него же переведён G3c. Маркеров 80 (было 78);
  - `ProjectionCase`: `check_project/2` с хелперами и тип `unhandled` удалены; у `rolled_back` ушёл параметр `run` —
    звать его с `Savepoint.run/2` больше некому; блок «общее» распущен — единственный вызывающий `check_clear/2`.
    Тест отката перенесён на `check_clear/2` (`BrokenProjection` оставляет таблицу названий непустой; мутацией
    «без отката» тест падает);
  - `BrokenProjection` получил clause `Closed`; `Renamed` по-прежнему падает в приватной функции — отказ на
    фикстуре `check_clear` откатывает и идёт дальше;
  - сверх перечня: `14-events-outbox.md` и пример «плохо» в `app/13-repos.md` приписывали полноту тесту. Проверено
    вручную, что делегирование `%mod{} = event when mod in @agg_events` в проектор другого файла без clause сборка
    ловит (домен проектора того же проекта протекает в `project/1`), поэтому довод примера переписан на
    читаемость, а не на слепоту проверки.
- 2026-09-17 — по ревью: G1 и G3a разнесены по модулям (одна ошибка — один модуль), тест отката `check_clear`,
  `@doc` `BrokenProjection.project/1`. Не принято: `@spec` у функций-проверок — механика тикета 04, `@doc false`
  хелперы макроса; «делегирование сборка не видит» — опровергнуто пробой; пункт CHANGELOG на довод примера
  `app/13-repos.md` — норма не менялась, пункт `ProjectionCase` дополнен; переименование блока «полнота clear» и
  вынос общего цикла `project_checks` / `evolve_checks` — две короткие формы с разными аргументами.
