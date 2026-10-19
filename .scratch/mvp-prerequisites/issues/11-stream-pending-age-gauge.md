# 11: Gauge возраста неподтверждённого сообщения Stream

**What to build:** дежурный видит, сколько секунд самое старое прочитанное, но не подтверждённое сообщение ждёт у
подписчика Stream. Алерт на застрявшего подписчика не срабатывает на тихом топике.

Спека — «Эксплуатация», gauge отставания Stream.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Первый шаг — проверить, отдаёт ли клиент `rabbitmq_stream` timestamp чанка. Итог записать в `## Comments`
      тикета.
- [x] Stream reader хранит время вместе с `pending`: timestamp чанка или момент получения чанка.
- [x] Polling-метрика `Core.Mq.PromEx` `<prefix>_mq_reader_pending_age_seconds` с метками, как у `reader_pending`.
      Значение — «сейчас минус время сообщения в `pending`», 0 при пустом `pending`.
- [x] Тест опроса плагина по состоянию reader. Живой брокер — только под тегом `:rabbit_stream`.
- [x] Moduledoc `Core.Mq.PromEx` и `21-observability.md`: смысл метрики и что она меряет при времени получения.
- [x] CHANGELOG «Новое».
- [x] `make` зелёный.

## Comments

### Проверка клиента `rabbitmq_stream` (2026-10-19)

- Клиент 0.4.2 отдаёт timestamp чанка: поле `timestamp` у `RabbitMQStream.OsirisChunk` разбирается из
  заголовка чанка Osiris (`timestamp::integer-size(64)`).
- Значение — мс Unix-времени по часам ноды брокера на момент записи чанка. Подтверждено живым тестом под
  `:rabbit_stream` (`test/core/mq/stream_test.exs`): timestamp прочитанного сообщения в пределах секунд от `put`.
- Ветка «момент получения чанка» не понадобилась: gauge меряет возраст сообщения с записи в брокер, и отставший
  подписчик даёт тот же рост, что и застрявший. Это сказано в moduledoc `Core.Mq.PromEx` и в `21-observability.md`
  (там же — рекомендованный алерт `MqStreamReaderPendingOld`).
