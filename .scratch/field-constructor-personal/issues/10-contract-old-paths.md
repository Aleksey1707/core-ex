# 10: Contract — удаление старых ролевых путей

**What to build:** завершение expand–contract: после миграции всех builder’ов на общий IR
удаляются старые ролевые атрибуты и пути `%Core.Codec.Field{}`, разрозненная диспетчеризация
`declared_fields/1` и прежние способы объявления полей/вариантов. Все builder’ы читают единую
интроспекцию. Это contract-шаг wide-рефакторинга: он возможен только когда ни один вызывающий не
опирается на старую форму.

**Blocked by:** 02, 03, 04, 05, 06, 09

**Status:** resolved

- [x] Старые ролевые атрибуты (`__struct_fields__`, `__es_payload_fields__`, `__es_value_changed__` как источник разбора) и пути `%Core.Codec.Field{}` удалены; все builder’ы на единой интроспекции.
- [x] Ручная диспетчеризация `declared_fields/1` в Labels/Event.Codec заменена чтением общего протокола.
- [x] `make` (boundary-check, rules-check, layout-check, spec-check, format-check, compile, compile-no-optional, consumer-check, xref, dialyzer, test, credo, audit) зелёный.
- [x] Публичная поверхность и wire-форма соответствуют новой модели; старых опций объявления полей/вариантов не осталось.

## CHANGELOG

### Ломающие изменения контракта

- `%Core.Codec.Field{}` и модуль `Core.Codec.Field` удалены: грамматику спеки поля разбирает
  `Core.Field` (`Core.Field.Spec` — виды и allowlist хоста, `Core.Field.declare!/3` — декларация в
  IR), второго разбора и второй формы поля нет. У потребителя `Core.Codec.Field.struct_fields(M)`
  заменяется на `Core.Field.introspect(M)`; `Core.Codec.Field.fields!/2`, `variant_fields!/4`,
  `normalize!/3`, `subjects/1`, `destroyable_places/1` и `typespec/1` удалены — поля объявляет
  декларация типа, а не плагин.
- Ролевые атрибуты и их читатели удалены: `__struct_fields__/0` (`Core.Struct`),
  `__es_payload_fields__/0` (`Core.Es.Event.Payload`), `__es_value_changed__/0`
  (`Core.Es.ValueChanged`), `Core.Struct.declared_fields/1`,
  `Core.Es.Event.Payload.declared_fields/1`, `Core.Es.ValueChanged.declared/1`. Единственная
  интроспекция полей — `__core_fields__/0` (читает `Core.Field.introspect/1`), вариантов —
  `__core_variants__/0`. Было `Mod.__struct_fields__()` / `Mod.__es_payload_fields__()` → стало
  `Core.Field.introspect(Mod)`; `Mod.__es_value_changed__()` → `Core.Field.introspect(Mod)` поля
  `old_value` / `new_value`.
- Wire-форма нагрузки события выводится по декларации; «нагрузка по полям» отличается от
  нагрузки-сущности с плагином тем, что объявляет позиционный конструктор `new/N` в размер
  декларации (`Core.Es.Event.Payload` и `Core.Es.ValueChanged`). `Core.Struct` конструктора не
  объявляет, поэтому сущность даже с `__core_fields__/0` остаётся нагрузкой плагина.
