# 12: Внешний вызов

**What to build:** автор адаптера внешней системы оборачивает вызов одной функцией. У вызова появляются span
(с внешней системой в графе сервисов), telemetry и метрики длительности и исходов по системе и операции. Исход
определяет классификатор вызывающего. Результат вызова возвращается без изменений.

Спека — «Внешний вызов»; `CONTEXT.md` — «Внешний вызов».

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `Core.External.call(system, operation, fun, opts)`:
      - `system` и `operation` — атомы;
      - обязательная `outcome:` — функция «результат → `:ok | :timeout | :down | :rejected`»;
      - иное значение — ошибка программиста.
- [ ] Словарь `Core.Otel.External`:
      - span `"<system> <operation>"`, `kind: :client`;
      - атрибуты `core.external.system`, `core.external.operation`, `core.external.outcome`, `peer.service`;
      - статус error у `timeout`, `down` и исключения; у `rejected` — нет.
- [ ] Исключение в `fun` — `record_error`, исход `exception`, повторный `raise`.
- [ ] `:telemetry.span` с префиксом `[:external, :call]`, метаданные `system`, `operation`, `outcome`.
- [ ] `Core.External.PromEx`: гистограмма `<prefix>_external_call_duration_milliseconds` и счётчик
      `<prefix>_external_call_total` с метками `system`, `operation`, `outcome`.
- [ ] Тесты с тестовым экспортёром OTel SDK и telemetry-обработчиком:
      - span по каждому исходу;
      - исключение;
      - результат без изменений.
- [ ] Тест описания метрик плагина.
- [ ] Свод `21-observability.md`: словарь, метрики, алерты `ExternalCallFailing` и `ExternalCallSlow`. App-ярус:
      адаптер внешней системы зовёт `Core.External.call`. CHANGELOG «Новое».
- [ ] `make` зелёный.
