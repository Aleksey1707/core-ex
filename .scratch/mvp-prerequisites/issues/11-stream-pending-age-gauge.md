# 11: Gauge возраста неподтверждённого сообщения Stream

**What to build:** дежурный видит, сколько секунд самое старое прочитанное, но не подтверждённое сообщение ждёт у
подписчика Stream. Алерт на застрявшего подписчика не срабатывает на тихом топике.

Спека — «Эксплуатация», gauge отставания Stream.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Первый шаг — проверить, отдаёт ли клиент `rabbitmq_stream` timestamp чанка. Итог записать в `## Comments`
      тикета.
- [ ] Stream reader хранит время вместе с `pending`: timestamp чанка или момент получения чанка.
- [ ] Polling-метрика `Core.Mq.PromEx` `<prefix>_mq_reader_pending_age_seconds` с метками, как у `reader_pending`.
      Значение — «сейчас минус время сообщения в `pending`», 0 при пустом `pending`.
- [ ] Тест опроса плагина по состоянию reader. Живой брокер — только под тегом `:rabbit_stream`.
- [ ] Moduledoc `Core.Mq.PromEx` и `21-observability.md`: смысл метрики и что она меряет при времени получения.
- [ ] CHANGELOG «Новое».
- [ ] `make` зелёный.
