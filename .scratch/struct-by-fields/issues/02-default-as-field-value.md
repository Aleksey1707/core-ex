# 02: `default:` — значение поля

**What to build:** автор задаёт полю значение по умолчанию выражением (`0`, `:draft`, `Currency.new!("RUB")`,
`DeliveryID.from_number!(42)`, `@rub`), и ключ этого поля перестаёт быть обязательным. Вид значения проверяет
сборка модуля.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] `Core.Helper.Opts` пропускает выражение в `default:` поля внутри литерального `fields:`; остальная
      `fields:` по-прежнему обязана быть литералом.
- [ ] Нормализатор режима `:struct` держит AST `default:`; у плагина `default:` остаётся wire-литералом.
- [ ] `@enforce_keys` — поля без `default:`; `defstruct` получает вычисленное значение.
- [ ] Валидатор в теле (`@doc false` у `Core.Struct`) проверяет вид результата: struct своего Prim, значение
      Enum, значение `type:`, struct `entity:` / вариант `union:`, `list:` поэлементно, `nil` — только при
      `optional: true`.
- [ ] `CompileError` на `default:` не того вида, на `default: nil` без `optional: true`, на `default:` у поля с
      Prim `personal: true` или `sensitive:`.
- [ ] Тесты: ключ с `default:` можно не указывать; значение по умолчанию каждого вида; каждый отказ.
- [ ] `@moduledoc`: таблица «`optional:` × `default:` → обязательный ключ и тип», предупреждение, что значение
      вычисляется один раз при сборке (`now!` / `generate` — ошибка).
- [ ] CHANGELOG: пункт из 01 дополняется, нового не заводится.
- [ ] `make` зелёный.
