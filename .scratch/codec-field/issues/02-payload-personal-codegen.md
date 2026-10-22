# 02: ПДн-генерация нагрузки — в `Core.Es.Event.Payload`

**What to build:** генерация нагрузки события с персональными данными — маркер `$pd` на месте поля с
`subject:` при дампе, загрузка маркера и `%Core.Es.Personal.Destroyed{}` на уничтоженном значении, редакция
ошибки, guards дампа и `new` — и смысловые проверки `subject:` живут в `Core.Es.Event.Payload`, владельце
нагрузки по полям. `Core.Codec.Plugin.Fields` генерирует только `dump` / `load` плагина и открывает поштучные
блоки значения поля, из которых Payload собирает свои клаузы. Wire, ошибки и сгенерированный код у
потребителя не меняются. Спека — `../spec.md`, user stories 13–15, 17–23, 27–29; «Implementation Decisions» —
`Core.Codec.Plugin.Fields`, `Core.Es.Event.Payload`.

**Blocked by:** 01 — Поле спеки — struct в `Core.Codec.Field`

**Status:** ready-for-agent

- [ ] В `Core.Codec.Plugin.Fields` нет кода персональных данных: маркера, `subject`-guards, загрузки `$pd`,
      редакции.
- [ ] `Core.Codec.Plugin.Fields` открывает `@doc false` поштучные блоки значения поля (дамп значения,
      загрузка значения, guard поля, переменная поля); хуков «оберни значение» у генератора нет.
- [ ] `Core.Es.Event.Payload` генерирует дамп нагрузки с маркером, guards дампа и `new`, загрузку нагрузки с
      клаузами маркера и уничтоженного значения из этих блоков.
- [ ] Смысловые проверки `subject:` (UUID-субъект, персональный Prim, необязательность субъекта,
      `:aggregate_id`) — в `Core.Es.Event.Payload`; грамматика знает `subject:` только как ключ режима
      нагрузки. Тексты `CompileError` не изменились.
- [ ] Рантайм-хелперы ошибки запечатанного маркера и редакции причины переехали в `Core.Es.Event.Payload`;
      сгенерированный код ссылается на них там.
- [ ] `Core.Es.Event.Codec` зовёт генерацию нагрузки у `Core.Es.Event.Payload`, а не у плагина.
- [ ] Wire нагрузки, маркер `$pd`, коды `:invalid_value` / `:sealed_personal_value` и `ns: :codec` не
      изменились: golden-фикстуры, тесты нагрузки с ПДн, проекций с ПДн и тестового хелпера ПДн проходят без
      правки ожиданий.
- [ ] `docs/rules/12-errors.md`: в таблице кодов источник `:sealed_personal_value` — нагрузка события.
- [ ] CHANGELOG не правится.
- [ ] `make` зелёный, включая `consumer-check`.
