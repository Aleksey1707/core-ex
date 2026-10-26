# 03: Роли — event-sourced агрегат и команда

**What to build:** состояние event-sourced агрегата и команда объявляются структурой по полям. Агрегат ломает
сборку на поле состояния, которое не допускает `nil`, а фикстура-потребитель держит храповик вывода типов на
сгенерированном struct.

**Blocked by:** 01

**Status:** resolved

- [x] `Core.Es.Aggregate` на `@after_compile`: при `__struct_fields__/0` поле без `optional: true`, кроме `id`, —
      `CompileError`. Ручной `defstruct` не проверяется.
- [x] `Core.Es.Cmd` без изменений принимает структуру по полям: `by` / `at` без `default:` — обязательные ключи.
- [x] Пример в `@moduledoc` `Core.Es.Cmd` — на `use Core.Struct`.
- [x] Тесты в тестах агрегата и команды через их `use`: отказ на поле без `optional:`, успех на корректном
      состоянии, команда со структурой по полям.
- [x] Фикстура-потребитель: одна команда и состояние одного event-sourced агрегата — на `use Core.Struct`;
      `make consumer-check` зелёный.
- [x] CHANGELOG: пункт из 01 дополняется.
- [x] `make` зелёный.
