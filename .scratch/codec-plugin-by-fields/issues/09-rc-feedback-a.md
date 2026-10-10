# 09: Отзыв rc-проверки у потребителя A

**Status:** resolved

**Blocked by:** 07.

**What to build:** правки по проверке неопубликованного плагина по полям на потребителе A.

- [x] Форма ключей дампа: в CHANGELOG — «было → стало» для вызывающих (`dumped.code` → `dumped["code"]`,
      `insert_all`, `Map.put`); норма «ключи-строки» у ручных плагинов (`docs/rules/11-domain.md`) и пример
      `to_model` (`docs/rules/13-repos.md`, «Schema»); `Core.Outbox.Codec` переведён на `fields:`.
- [x] Мёртвая `load_payload(mod, …) when mod in […]` ловится сборкой (разбор guard `in`).
- [x] Шум диагностики: ручная клауза на выводимый тип — `CompileError` в `__before_compile__`, вывод типов до
      тела мёртвой клаузы не доходит.
- [x] Union с конвертом — вынесен в `08-union-envelope.md` (needs-triage).
- [x] `@spec` у `dump/2` / `load/3` плагина с `fields:` и у `dump_payload/2` / `load_payload/3` кодека с
      выводимыми клаузами — `CompileError`; исключение в `docs/rules/20-agreements.md`.
