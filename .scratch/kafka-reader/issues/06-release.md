# 06: Релиз с чтением Kafka

**What to build:** потребитель поднимает версию библиотеки и получает чтение Kafka, фильтр
подписчика, отказ без повторов и DLQ в Postgres одним релизом с описанием миграции.

**Blocked by:** 01, 02, 03, 04, 05, 07

**Status:** done

**Spec:** [Чтение из Kafka](../spec.md)

- [x] Проверка rc на потребителе — `docs/agents/release-check.md`.
- [x] `CHANGELOG.md`: раздел версии с шагами миграции (миграции таблиц DLQ и смещений читателя
      Kafka, новые опции подписчика, клиент `:klife` → `:brod` в `deps` и handle `Kafka.Writer`,
      расширенная модель `Mq.Message`).
- [x] Версия поднята, тег выставлен.

## Итог

Проверка rc на потребителе A (последний выпуск у него — `v0.9.0`, закоммиченное состояние ветки
разработки; `path:` на рабочую копию, `deps/core` — симлинк, PLT пересобран):
`mix compile --force --warnings-as-errors`, `boundary-check`, `rules-check`, `layout-check`,
`format-check`, `mix credo --strict`, `mix dialyzer`, `mix test` (1871 тест) — без замечаний.
Kafka потребитель A не использует; из «было → стало» его касаются `Mq.Message` (литералом
не матчится, тело из Stream не бывает `nil`), `Mq.HeaderKey` (имена в lowercase) и метка `reason`
у `mq_subscriber_dlq_total` (алерт `MqSubscriberDlq` агрегирует `sum by (topic, dlq_topic)`) —
правка кода не нужна.

`CHANGELOG.md`: пункты о миграциях таблиц читателя Kafka и DLQ, опциях подписчика (`filter:`,
`{:reject, _}`, `dlq_writer:` на `Core.Mq.Dlq.Writer`), `:klife` → `:brod` и модели `Mq.Message`
заведены тикетами 01–05, 07 и сведены в раздел `## 0.10.0`; тег `v0.10.0` — на коммите сведения.
