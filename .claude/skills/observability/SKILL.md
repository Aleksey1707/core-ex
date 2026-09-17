---
name: observability
description: "Свод правил наблюдаемости библиотеки Core: разделение метрик (telemetry + PromEx), трейсов (Core.Otel) и логов, метрики event sourcing в Core.Es.PromEx (алерты проекций — в 22-projections.md), зависимость от opentelemetry_api и требование no-op без SDK, словари (Core.Otel.Messaging, Core.Otel.Es), где ставить span и где он запрещён, корневой span пачки проекции и span ожидания проекции await и span команды процесса агрегата execute на call site, запрет контекста трейса в es_events, атрибуты и record_error, trace_id в metadata логов, baggage, тесты трассировки, рекомендованные алерты подсистем на метриках Core.*.PromEx (outbox, MQ, подписчики и DLQ, workers, кеш) с PromQL по именам my_app_prom_ex_<плагин>_… Использовать при добавлении метрики, span'а или атрибута, при правке PromEx-плагинов Core.*.PromEx и Core.Otel, при заведении алертов на подсистемы библиотеки."
---

# 21-observability.md

Прочитай `docs/rules/21-observability.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
