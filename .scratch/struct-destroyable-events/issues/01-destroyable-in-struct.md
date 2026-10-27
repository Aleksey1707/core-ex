# 01: `destroyable:` в структуре по полям

**What to build:** автор состояния event-sourced агрегата помечает поле `destroyable: true`, и `@type t`
структуры по полям допускает уничтоженное ПДн-значение там, где его кладёт `evolve/2`: в поле верхнего уровня,
в элементе `list:`, в значении `map:`, в поле вложенной сущности. Фикстура-потребитель держит храповик вывода
типов на поле состояния с ПДн. Спека — `../spec.md`, решение — ADR-0092.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `destroyable: true` у поля верхнего уровня любого вида: тип — `T | Core.Es.Personal.Destroyed.t()`, с
      `optional: true` ещё `| nil`.
- [x] `destroyable: true` у спеки элемента `list:` (и вложенных `list:`) и у спеки значения `map:`: `Destroyed`
      добавляется к типу элемента и значения.
- [x] `CompileError` с префиксом `Struct: fields: <поле>: …`: `destroyable:` у элемента `set:`, у ключа `map:`
      (текст — равные уничтоженные значения не идентифицируют запись), значение не `true`
      («ожидается true, получено …»).
- [x] `destroyable:` в режимах плагина по полям, `Payload` и `View` — `CompileError`.
- [x] Плагин по полям при сверке со структурой `destroyable:` не сравнивает: плагин рядом со структурой с
      уничтожаемым полем собирается без повтора опции.
- [x] Нормализованное поле `__struct_fields__/0` несёт признак уничтожаемости (форма — не контракт) — его прочтёт
      проверка команды в 02.
- [x] `@moduledoc` `Core.Struct`: опция в таблице и пример состояния с уничтожаемым полем; текст не называет
      поле «персональным».
- [x] Тесты: `@type t` через `Code.Typespec.fetch_types/1` у модулей `test/support/struct_fixture.ex` (верхний
      уровень с `optional:` и без, элемент `list:`, значение `map:`); отказы — `Code.eval_quoted`; отказы
      режимов — в тестах плагина, `Payload`, `View`.
- [x] Фикстура-потребитель: поле состояния `Account.holder` — `destroyable: true`; `make consumer-check` зелёный.
- [x] `docs/rules/23-personal-data.md`: норма MUST — каждое место состояния, куда `evolve/2` кладёт значение поля
      нагрузки с `subject:`, объявляется `destroyable: true`; сборка этого не проверяет; пример «хорошо» с
      `holder`. `docs/rules/11-domain.md`, структура по полям: `destroyable:`. `make rules-check` зелёный.
- [x] CHANGELOG, «Изменения контракта макросов»: `destroyable:`, было → стало для поля состояния с ПДн.
- [x] `make` зелёный.
