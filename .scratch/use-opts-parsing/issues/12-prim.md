# 12: Prim — единый пролог обёрток

**What to build:** автор Prim получает опечатку в ключе любой обёртки при раскрытии `use`, атрибут в опции-литерале
(`kind:`, `sensitive:`, `personal:`) — `CompileError` «ожидается литерал», а `name: first_line(@moduledoc)`, захваты
`mutate:` / `validate:`, `re: ~r/…/`, `max_len: @max_len`, `namespace: Mod.namespace()` по-прежнему законны. Переводятся
`Core.Prim`, `Prim.Wrapper`, семь обёрток (`Prim.String`, `.Integer`, `.Decimal`, `.UUID`, `.Date`, `.DateTime`,
`Prim.Compose`) и `Prim.Opts` одним срезом, без переходного режима. Спека — `../spec.md`, «Prim»; ADR-0085.

**Blocked by:** 10.

**Status:** resolved

- [x] `Prim.Opts.prepare!` — единый пролог семи обёрток при раскрытии: `expand!` → `validate!` → `literal!` → `kind!` →
  `validate_opts!` обёртки, без шага флагов. Инлайн-пролог прототипа в `Prim.String` не перенесён.
- [x] Протокол `Prim.Wrapper`: `required_keys/0` / `optional_keys/0` остались, добавлен `expression_keys/0` (общие
  `name` / `mutate` / `validate` и свои обёртки: `re`, `max_len`, `namespace` …).
- [x] Владение ключами: `name` / `sensitive` / `personal` — у `Core.Prim` (обёртка отдаёт как есть, ошибка с меткой
  `Prim:`, `binary_value!(name)` в обёртке ушёл); `kind` — у обёртки (`validate_kind!` против `native_kind`);
  `mutate` / `validate` — у обёртки, переименование в `custom_*`; проверка `custom_*` у `Core.Prim` осталась для прямых
  вызовов; `sensitive` / `personal` у `Prim.Compose` — у самой `Prim.Compose`.
- [x] У `Core.Prim` `kind` / `sensitive` / `personal` — литералы; выражения — `name:`, `cast:` / `mutate:` /
  `validate:` / `custom_*`, `re:`, `max_len:`, `namespace:`. `value_type:` у `Core.Prim` и `of:` у `Prim.Compose` идут
  через общий пролог, а не сырым AST.
- [x] `Prim.Opts.bad!/4` переведён на `reject!`.
- [x] `@moduledoc` `Core.Prim` и обёрток называют опции-выражения.
- [x] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции-литерале — «ожидается литерал»; неверное
  выражение (`name: @n` при `@n 1`) — в теле, с меткой.
- [x] CHANGELOG: накопительный пункт «Опции `use` — только литералом, кроме объявленных выражений» в «Не выпущено» →
  «Изменения контракта макросов» (текст — спека). Пункта нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать строки `use Core.Prim` и обёрток.
- [x] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [x] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
