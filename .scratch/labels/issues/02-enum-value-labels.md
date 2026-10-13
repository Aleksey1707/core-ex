# 02: Подписи значений Enum

**Status:** resolved

**Blocked by:** 01.

**What to build:** автор приложения объявляет подписи значений у Enum (`use Core.Labels.Values, labels:` после
`use Core.Enum`) и получает `label/1` и `labels/0` в порядке `values/0`; поле нагрузки вида `enum:` выходит в
сведения текстом — подписью значения. Спека — `../spec.md`, «Модули домена», user stories 18–20; ADR-0063.

- [x] `use Core.Labels.Values`: обязательная `labels:`; без `use Core.Enum` — `CompileError`; значение без подписи,
      подпись вне Enum, повтор, пустая подпись, не keyword-список — `CompileError`.
- [x] `label/1` принимает только значения Enum (голова закрывает домен, иное — `FunctionClauseError`);
      `labels/0` — пары в порядке `values/0`.
- [x] `Details.build/1`: поле `enum:` — сведение `text` с подписью значения; `nil` — `value: nil`.
- [x] Тесты: выход `label/1` / `labels/0`, сведение enum-поля, отказы сборки.
- [x] Фикстура-потребитель: Enum с подписями и вызов `label/1` с известным значением; храповик вывода типов
      `make consumer-check` зелёный.
- [x] Свод: механизм — `docs/rules/11-domain.md`, «Подписи»; `docs/rules/app/11-domain.md` — ручные `label/1` /
      `labels/0` MUST NOT, строка таблицы `@moduledoc` подписью не служит.
- [x] `CHANGELOG.md` — дополняется пункт подсистемы подписей из «Не выпущено».
- [x] `make` зелёный.
