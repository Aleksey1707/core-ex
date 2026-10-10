# 06: Выводимые клаузы для нагрузки-Prim и `Es.ValueChanged`

**Status:** resolved

**Blocked by:** 03, 05.

**What to build:** событие, чья нагрузка — Prim или `use Core.Es.ValueChanged`, кодируется без ручных клауз в
`Event.Codec`. Спека — `../spec.md`, «`Core.Es.Event.Codec`»; ADR-0056.

- [x] Нагрузка-Prim: клаузы `codec.dump(payload)` / `codec.load(Prim, wire)` выводятся сами.
- [x] `Core.Es.ValueChanged` отдаёт `type:` и `nilable:` интроспекцией; `Event.Codec` строит спеку `old_value` /
      `new_value`: Prim → `prim:`, `Core.Enum` → `enum:`, иначе `entity:`; `optional:` при `nilable: true`.
- [x] Ручная клауза для такого события — «never match»; проверки полноты проходят без ручного кода.
- [x] Конверт совпадает с конвертом ручного кодека той же нагрузки (Prim-нагрузка — голое значение, как
      `codec.dump(p)` сейчас).
- [x] Тесты фасада на оба вида нагрузки, включая `nilable: true` и enum-тип `ValueChanged`.
- [x] `fixtures/consumer`: событие с нагрузкой-Prim и с `ValueChanged` без ручных клауз и без предупреждений.
- [x] `docs/rules/11-domain.md`, `@moduledoc` `Core.Es.Event.Codec` и `Core.Es.ValueChanged`.
- [x] `CHANGELOG.md`: дополняется пункт о выводимых клаузах `Event.Codec`.
- [x] `make` зелёный.
