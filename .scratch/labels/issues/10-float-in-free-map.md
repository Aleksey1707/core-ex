# 10: float в свободной map'е

**Status:** resolved

**Blocked by:** —

**What to build:** `Core.Labels.Details.inferred/2` отдаёт любое число видом `:number`, а
`Core.Web.Event.Details.number/1` принимает только строку, integer и `Decimal`: float в значении свободной
map'ы (`type: :map` с `[label:, key:, value:]`) роняет страницу событий `FunctionClauseError`. Wire обещает число
строкой в нормальной записи (`Core.Web.Event`, «`:number`»), а `Float.to_string(1.0e20)` даёт экспоненту —
поэтому float переводится через `Decimal`.

- [x] `number/1`: клауза float — `Decimal.from_float/1` → `Decimal.to_string(:normal)`.
- [x] Строка `:number` в moduledoc `Core.Web.Event` называет float.
- [x] Тест: значение-float свободной map'ы на wire — нормальная запись (в т. ч. `1.0e20`, `1.0e-7`).
- [x] `make` зелёный.

Вне тикета: `inferred/2` не сужается до integer — вид сведения не зависит от значения. CHANGELOG не
правится: подсистема не выпущена, поведение «до» выпуска не существовало.
