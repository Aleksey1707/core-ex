# 01: `use Core.Struct` без `default:`

**What to build:** автор объявляет структуру по полям `use Core.Struct, fields: [...]` на языке спеки полей и
получает `defstruct`, обязательные ключи и `@type t` из одной декларации. Значений по умолчанию пока нет: все поля —
обязательные ключи. Спека — `.scratch/struct-by-fields/spec.md`, решение — ADR-0090.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Builder `Core.Struct` с меткой `"Struct"`, пролог `Helper.Opts.expand!/3` → `validate!` → `literal!/3`
      (ADR-0085), обязательный ключ `fields:`.
- [x] `Core.Codec.Field` получает режим `:struct`; остальные режимы не меняются.
- [x] Виды `prim:` / `enum:` / `entity:` / `union:` / `list:` / `type:` дают в `@type t` тип своего вида;
      `optional: true` добавляет `| nil`.
- [x] `@enforce_keys` — все поля; `defstruct` — все поля; `__struct_fields__/0` (`@doc false`).
- [x] Модули спеки проверяются в теле: Prim, вложенный выше `use`, собирается.
- [x] `CompileError` с префиксом `Struct: fields: <поле>: …` на `wire:`, `subject:`, `default:` (временно),
      не-Prim в `prim:`, не-Enum в `enum:`, несобранный модуль, неизвестное значение `type:`, повтор поля,
      нелитеральный `fields:`.
- [x] Тесты через поверхность `use`: `%S{}`, `Code.eval_string("%S{}")` → `ArgumentError` со списком ключей,
      `Code.Typespec.fetch_types/1` у модуля в `.beam`, `Code.eval_quoted` → `CompileError` на каждый отказ.
- [x] `@moduledoc` с примером, таблицей видов и перечнем отказов; `optional:` не называется «необязательным
      ключом».
- [x] CHANGELOG, «Не выпущено» → «Новое»: пункт о `Core.Struct`.
- [x] `make` зелёный.
