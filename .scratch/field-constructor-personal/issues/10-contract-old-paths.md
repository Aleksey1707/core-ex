# 10: Contract — удаление старых ролевых путей

**What to build:** завершение expand–contract: после миграции всех builder’ов на общий IR
удаляются старые ролевые атрибуты и пути `%Core.Codec.Field{}`, разрозненная диспетчеризация
`declared_fields/1` и прежние способы объявления полей/вариантов. Все builder’ы читают единую
интроспекцию. Это contract-шаг wide-рефакторинга: он возможен только когда ни один вызывающий не
опирается на старую форму.

**Blocked by:** 02, 03, 04, 05, 06, 09

**Status:** ready-for-agent

- [ ] Старые ролевые атрибуты (`__struct_fields__`, `__es_payload_fields__`, `__es_value_changed__` как источник разбора) и пути `%Core.Codec.Field{}` удалены; все builder’ы на единой интроспекции.
- [ ] Ручная диспетчеризация `declared_fields/1` в Labels/Event.Codec заменена чтением общего протокола.
- [ ] `make` (boundary-check, rules-check, layout-check, spec-check, format-check, compile, compile-no-optional, consumer-check, xref, dialyzer, test, credo) зелёный.
- [ ] Публичная поверхность и wire-форма соответствуют новой модели; старых опций объявления полей/вариантов не осталось.
