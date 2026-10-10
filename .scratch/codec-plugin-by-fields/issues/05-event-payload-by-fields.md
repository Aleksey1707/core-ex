# 05: Нагрузка события по полям

**Status:** ready-for-agent

**Blocked by:** 02.

**What to build:** автор события объявляет нагрузку `use Core.Es.Event.Payload, fields: [...]` — и получает struct,
позиционный `new`, `@type t`, а `Event.Codec` перестаёт требовать для этого события `dump_payload` / `load_payload`.
Конверт совпадает с тем, что давал ручной кодек. Спека — `../spec.md`, «`use Core.Es.Event.Payload`»,
«`Core.Es.Event.Codec`»; ADR-0056.

- [ ] `use Core.Es.Event.Payload, fields:` — та же спека полей; `default:` — `CompileError` (развитие события — тег и
      апкаст, ADR-0010 / ADR-0020).
- [ ] Порождаются `@enforce_keys` (все поля, кроме `optional:`), `defstruct`, `@type t` по видам, позиционный `new/N`
      в порядке объявления с головой по видам, маркер со спекой.
- [ ] `Event.Codec` генерирует клаузы `dump_payload/2` / `load_payload/3` для события с нагрузкой по полям тем же
      генератором, что у плагина; ручная клауза для такого события — «never match».
- [ ] Проверки полноты (`Core.Es.Check`) для таких событий проходят без ручного кода.
- [ ] Нагрузка по полям в фасаде не регистрируется.
- [ ] Тесты фасада: `dump(event)` / `load(Agg.Event, конверт)`; конверт равен конверту ручного кодека той же
      нагрузки; golden-фикстура события с нагрузкой по полям проходит `Core.Es.EventCompatCase`; тест сборки на
      `default:`.
- [ ] `fixtures/consumer`: событие с нагрузкой по полям без предупреждений; `# expect:` на нагрузку не того вида в
      `new` у `draft` и на ручную клаузу для события с выводимой нагрузкой.
- [ ] `docs/rules/11-domain.md` (и `14-events-outbox.md`, если там описаны клаузы нагрузки): нагрузка по полям,
      выводимые клаузы; `@moduledoc` `Core.Es.Event.Codec` и нового `Core.Es.Event.Payload`.
- [ ] `CHANGELOG.md`: «Новое» — нагрузка по полям; «Изменения контракта макросов» — выводимые клаузы `Event.Codec`.
- [ ] `make` зелёный, включая `consumer-check`.
