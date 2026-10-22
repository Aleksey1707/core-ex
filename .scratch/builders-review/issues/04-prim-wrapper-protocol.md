# 04: Prim-обёртки — общий протокол в одном месте

**Status:** needs-triage

**Blocked by:** None (can start immediately)

**Сила:** Strong.

**Файлы:** `lib/core/prim/{string,integer,decimal,uuid,date,date_time,compose}.ex`, `lib/core/prim/wrapper.ex` (44 строки), `lib/core/prim.ex` (~45).

**Проблема.**
- Каждая из семи обёрток вручную пробрасывает в базу одни и те же 6–7 опций: `custom_mutate: Keyword.get(opts, :mutate)`, `custom_validate:`, `name:`, `sensitive:`, `personal:` (например, `string.ex` ~45–52, `date.ex` ~32–37, `uuid.ex` ~62–67).
- Каждая повторяет `Prim.Opts.boolean!(opts, ~w(... sensitive personal)a)` в `validate_opts!`.
- Каждая вписывает общие ключи `kind mutate validate sensitive personal` в свой `optional:`.
- `Wrapper` — это четыре геттера атрибутов: по deletion test модуль shallow.
- Базовый `use Core.Prim` проверяет только required-ключи, поэтому опечатку на уровне базы он не ловит. Ключи при этом ещё и переименовываются (`mutate` → `custom_mutate`).

**Что изменилось бы.** Обёртка объявляет только свои опции. Общие ключи, их проверку и проброс в базу берёт на себя `Wrapper` / `Prim.Opts`.

**Выигрыш.** Leverage: новая общая опция (как недавний `personal:`) добавляется в одном месте вместо 21. Обёртки перестают расходиться. Опечатка ключа ловится на базе.

**ADR:** конфликта нет.
