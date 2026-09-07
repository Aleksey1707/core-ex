---
name: observability
description: "Свод правил наблюдаемости библиотеки Core: разделение метрик (telemetry + PromEx), трейсов (Core.Otel) и логов, зависимость от opentelemetry_api и требование no-op без SDK, словари semconv (Core.Otel.Messaging), где ставить span и где он запрещён, атрибуты и record_error, trace_id в metadata логов, baggage, тесты трассировки. Использовать при добавлении метрики, span'а или атрибута и при правке Core.Otel."
---

# 21-observability.md

Прочитай `docs/rules/21-observability.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
