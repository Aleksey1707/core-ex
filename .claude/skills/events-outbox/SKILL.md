---
name: events-outbox
description: "Свод правил событий и outbox библиотеки Core: накопление events в агрегате и flush в одной транзакции, <Aggregate>.Outbox и Es.Event.Codec (type:, уникальность тега внутри кодека, :unknown_event_type), совместимость событий (новый тег + апкаст) и golden-фикстуры, lifecycle outbox (Poller, Cleaner, Delivery.Mq, ключ Core.Outbox — только poller_name / pollers, аренда и fencing, запросы очереди по индексу, порядок доставки, requeue_failed, validate_partition!), трассировка цепочки, контракт обработчика MqSubscriberReliable (:ok / {:skip, _} / {:error, _}) и выход в DLQ; конфигурация OUTBOX_*, единственность поллера на нодах, runbook по :failed и идемпотентность задач приложения — в deps/core/docs/rules/app/14-events-outbox.md. Использовать при добавлении события, правке кодека событий, работе с outbox и MQ-подписчиками, разборе записей в :failed и сообщений в DLQ."
---

# 14-events-outbox.md

Прочитай `docs/rules/14-events-outbox.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
