# 12: видимый список map'ов — только `:hidden`

**Status:** resolved

**Blocked by:** —

**What to build:** поле `list: [type: :map]` подписать нельзя: строку отвергает проверка `maps` (`map?/1`
спускается в `{:list, _}`), подпись `[label:, key:, value:]` — проверка `not_maps` (требует
`{:type, :map}`), `Details.field_detail/3` знает map'у только на верхнем уровне. Решение — норма, а не новая
форма сведений: у такого поля единственное решение `:hidden`. Поддержки подписи map'ы для `{:list, _}` нет — ни
у одного потребителя такого поля нет.

- [x] `fields.ex`: сообщение проверки `maps` для `{:list, _}` не советует `[label:, key:, value:]` — только
      `:hidden`; для `{:type, :map}` сообщение прежнее.
- [x] `docs/rules/11-domain.md`, раздел `Core.Labels.Fields`: список map'ов — только `:hidden`.
- [x] Тест: `list: [type: :map]` без решения — `CompileError` с новым текстом.
- [x] `make` зелёный.

CHANGELOG не правится: меняется текст сообщения.
