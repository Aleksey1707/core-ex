# 12: Внешний вызов

**What to build:** автор адаптера внешней системы оборачивает вызов одной функцией. У вызова появляются span
(с внешней системой в графе сервисов), telemetry и метрики длительности и исходов по системе и операции. Исход
определяет классификатор вызывающего. Результат вызова возвращается без изменений.

Спека — «Внешний вызов»; `CONTEXT.md` — «Внешний вызов».

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `Core.External.call(system, operation, fun, opts)`:
      - `system` и `operation` — атомы;
      - обязательная `outcome:` — функция «результат → `:ok | :timeout | :down | :rejected`»;
      - иное значение — ошибка программиста.
- [x] Словарь `Core.Otel.External`:
      - span `"<system> <operation>"`, `kind: :client`;
      - атрибуты `core.external.system`, `core.external.operation`, `core.external.outcome`, `peer.service`;
      - статус error у `timeout`, `down` и исключения; у `rejected` — нет.
- [x] Исключение в `fun` — `record_error`, исход `exception`, повторный `raise`.
- [x] `:telemetry.span` с префиксом `[:external, :call]`, метаданные `system`, `operation`, `outcome`.
- [x] `Core.External.PromEx`: гистограмма `<prefix>_external_call_duration_milliseconds` и счётчик
      `<prefix>_external_call_total` с метками `system`, `operation`, `outcome`.
- [x] Тесты с тестовым экспортёром OTel SDK и telemetry-обработчиком:
      - span по каждому исходу;
      - исключение;
      - результат без изменений.
- [x] Тест описания метрик плагина.
- [x] Свод `21-observability.md`: словарь, метрики, алерты `ExternalCallFailing` и `ExternalCallSlow`. App-ярус:
      адаптер внешней системы зовёт `Core.External.call`. CHANGELOG «Новое».
- [x] `make` зелёный.

## Comments

### Решения реализации (2026-10-19)

- `record_error/1` фасада принимает только `%Error{}`, поэтому фасад получил `record_exception/3` и
  `record_failure/1`. `error.type`: у исключения — модуль (`RuntimeError`), у `exit`/`throw` — вид, у
  `timeout`/`down` — имя исхода. Текст исключения и стек в span не идут: в них бывает запрос адаптера с
  секретом или ПДн (`21-observability.md`, «Атрибуты»).
- Исключение ловится вместе с `exit` и `throw`: таймаут HTTP-клиента часто приходит `exit`. Все три вида —
  исход `exception`, поднимаются заново тем же видом и стеком.
- В telemetry исключение даёт `:stop` с `outcome: :exception`, а не событие `:exception`. Иначе
  длительности и счётчику исключений понадобилось бы второе определение метрики с тем же именем на
  другом событии.
- Без `outcome:` и при исходе вне множества — `ArgumentError`. Исход вне множества ловится после вызова,
  внутри span'ов.
