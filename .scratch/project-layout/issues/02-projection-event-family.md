# 02: `CompileError` проекции на семейство событий не `<Aggregate>.Event`

**What to build:** `use Core.Es.Projection` отказывает сборке, если событие из `events:` лежит не
в семействе `<Aggregate>.Event`. Сейчас такая проекция собирается, но clause `await/3` для её
агрегата молча не создаётся, и ошибка всплывает `FunctionClauseError` в рантайме.

**Blocked by:** None (can start immediately)

**Status:** done

**Spec:** [Раскладка потребителя](../spec.md) — «`use Core.Es.Projection`»

- [x] Событие, чей родительский модуль не оканчивается на `Event`, даёт `CompileError`,
      называющий событие и ожидаемую форму `<Aggregate>.Event.<Name>`.
- [x] Проекции над событиями в семействе `<Aggregate>.Event` собираются как раньше; `await/3`
      получает clause на каждый агрегат.
- [x] Тест проекции, describe «use»: новый случай рядом с существующими `CompileError`.
- [x] Комментарии кода и прошлые ссылки CHANGELOG на «раскладку `11-domain.md`» для кодека событий
      указывают на фактическое место нормы.
- [x] `22-projections.md` называет новый отказ сборки там, где перечислены остальные.
- [x] CHANGELOG, «Изменения контракта макросов»: было → стало для потребителя.
- [x] `make` зелёный.
