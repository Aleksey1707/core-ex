# 13: лишние поля struct'а изменения

**Status:** resolved

**Blocked by:** —

**What to build:** `fields.ex` у struct'а изменения (`change:`) проверяет только наличие `old_value` /
`new_value`; лишнее поле собирается и молча не выходит в сведения. У потребителя A такая проверка есть в своём
модуле подписей — без неё перевод ослабит контроль.

- [x] Обратная проверка: `fields -- ~w(old_value new_value)a` пусто, иначе `CompileError`
      «поля struct'а изменения вне `old_value` / `new_value`» с перечнем полей.
- [x] Moduledoc `Core.Labels.Fields` и `docs/rules/11-domain.md` — в списке того, что ломает сборку.
- [x] Тест: struct изменения с третьим полем — `CompileError` с именем поля.
- [x] `CHANGELOG.md` — дополняется пункт «Подписи событий» в «Новое».
- [x] `make` зелёный.
