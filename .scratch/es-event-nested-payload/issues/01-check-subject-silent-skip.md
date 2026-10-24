# 01: `Es.Event` — проверка `subject: :aggregate_id` молча пропускается на вложенном `Payload`

Status: resolved

Blocked by: None

## Что не так

`use Core.Es.Event` при раскрытии зовёт `check_subject!/2` (`lib/core/es/event.ex`): поле нагрузки с
`subject: :aggregate_id` требует UUID-Prim у `aggregate_id:` (ADR-0073). Проверка идёт через
`Helper.Module.exports?(payload, :__es_payload_fields__, 0)`.

Каноническая раскладка события — `Payload`, вложенный в модуль события до `use Core.Es.Event` (42 из 75 вызовов,
в том числе 8 в `fixtures/consumer`). При раскрытии тело события ещё не вычислено, вложенный `Payload` не собран:
`Code.ensure_compiled` отдаёт ошибку, `exports?` — `false`, `check_subject!` возвращает `:ok`. Событие с
`subject: :aggregate_id` при не-UUID `aggregate_id:` собирается без ошибки.

Тест (`test/core/es/event/payload_personal_test.exs`, «subject: :aggregate_id при не-UUID aggregate_id: проверяет
use Core.Es.Event») берёт невложенный, уже собранный `Payload` и дыры не видит.

## Что сделать

- Проверку `payload:` по модулю — в тело `use` (публичный `@doc false` валидатор, значение — `Macro.escape` литерала),
  с громким отказом на несобранном модуле (`ensure_compiled!` до `exports?`).
- Тест на вложенный `Payload` с `subject: :aggregate_id` при не-UUID `aggregate_id:` — `CompileError`.
- Убедиться, что вложенные `Payload` в `test/` и `fixtures/consumer/` везде объявлены до `use Core.Es.Event`:
  громкий отказ сделает обратный порядок ошибкой сборки.
- `CHANGELOG.md`: событие с неверным `subject: :aggregate_id` или с `Payload` ниже `use` у потребителя перестаёт
  собираться.
- `make` целиком, включая `consumer-check`.

Норма, по которой это чинится, — «Проверки опции-литерала по другим модулям»
(`.scratch/use-opts-parsing/issues/07-literal-module-checks.md`).
