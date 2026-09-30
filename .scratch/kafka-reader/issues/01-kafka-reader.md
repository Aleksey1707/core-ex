# 01: `Mq.ReaderReliable` для Kafka

**What to build:** потребитель подписывается на топики Kafka тем же `MqSubscriberReliable`, что и
на RabbitMQ Stream: `get` отдаёт следующее сообщение с ключом, заголовками, телом как есть и
позицией источника, `commit` фиксирует смещение, а после рестарта или смены ноды-владельца чтение
продолжается с зафиксированного смещения. Подписчик, у которого смещения ещё нет, читает топик с
начала. Работает на любой Kafka ≥ 0.11, в том числе без KIP-848.

**Blocked by:** 07

**Status:** ready-for-agent

**Spec:** [Чтение из Kafka](../spec.md)

**ADR:** [0032 — `Mq.Message` моделирует запись чужого топика](../../../docs/adr/0032-mq-message-models-foreign-topic-record.md),
[0033 — читатель Kafka без consumer group](../../../docs/adr/0033-kafka-reader-without-consumer-group.md),
[0034 — адаптер Kafka на `brod`](../../../docs/adr/0034-kafka-adapter-on-brod.md)

## Модель сообщения (ADR-0032)

- [ ] `Mq.Key` — собственный примитив над непустым `binary()` без верхнего предела и без
      UTF-8; модуль и API (`new/1`, `value/1`, struct) прежние.
- [ ] `Mq.HeaderKey` — любая непустая строка UTF-8 в нижнем регистре; повтор имени — последнее
      значение, null-значение — `""`.
- [ ] `Message.body :: binary() | nil`: `nil` — tombstone. `:brod` не различает null и пустое
      значение: `Kafka.Writer` публикует `nil` как tombstone (отказ на `""` — тикет 07);
      читатель отдаёт пустое значение как `nil`, пустой ключ — как `key: nil`.
- [ ] `Mq.Position` (`partition: non_neg_integer() | nil`, `offset: non_neg_integer()`) и
      `Message.position :: Mq.Position.t() | nil`; `Stream.Reader` заполняет смещение при
      `partition: nil`.
- [ ] `Stream.Codec`: ключ или значение заголовка не в UTF-8 и `nil`-тело — `{:error, _}`.

## Читатель (ADR-0033)

- [ ] `Core.Mq.Kafka.Reader` — GenServer, `Mq.ReaderReliable`, подписчик `brod_consumer`
      каждой партиции (`brod:subscribe/5`), без consumer group. Опции: `client:` (id клиента
      `:brod`, как handle `Kafka.Writer`), `topic:`, `subscriber_name:`, `repo:`; стартовая
      позиция без смещения — опция, по умолчанию earliest.
- [ ] Пачки `#kafka_message_set{}` — в буфер по партициям, `get` обходит партиции по кругу, одно
      сообщение в работе на читатель; буфер ограничен `prefetch_count`. Новые партиции —
      `brod:get_partitions_count/2` раз в интервал. Последовательность и head-of-line
      (повторяемое сообщение держит весь топик) — в `@moduledoc`.
- [ ] `get` без `commit` предыдущего отдаёт то же сообщение (повтор, как у `Stream.Reader`).
- [ ] Смещения — таблица БД потребителя, ключ `(subscriber_name, topic, partition)`, следующее
      смещение и время записи; миграция — хелпером библиотеки по образцу `Core.Outbox.Migration`.
      `commit` — синхронный upsert, затем `brod:consume_ack/4`.
- [ ] Одна активная нода на топик: аренда строкой с fencing-токеном по образцу поллера outbox.
      `commit` проверяет токен, у устаревшей ноды — `{:error, _}`; нода без аренды не подписана
      и отдаёт `:empty`; потеря аренды — отписка, сброс буфера и сообщения в работе.
- [ ] `OFFSET_OUT_OF_RANGE` при `offset_reset_policy: reset_by_subscriber` — `error` в лог,
      счётчик сброса в telemetry, переподписка с earliest.
- [ ] Смена лидера — внутри `brod_consumer`; перезапуск `brod_consumer` читатель видит по
      monitor и переподписывается с зафиксированного смещения, `get` — `:empty`, `warning` с
      ограниченной частотой. Неизвестный топик — ошибка, а не падение читателя.
- [ ] `high_wm_offset` последней пачки и `ts` последнего закоммиченного сообщения по партиции —
      в состоянии читателя для метрик отставания (тикет 05).
- [ ] Компилируется только при клиенте в `deps` (как `Kafka.Writer`);
      `Core.Mq.Kafka.ensure_available!/0` различает читателя.
- [ ] Wire-формат: тело — байты Kafka без конверта (ADR-0004, «Wire-формат принадлежит адаптеру»).

## Проверки и документы

- [ ] Тесты с живым брокером — тег `:kafka` и инфраструктура из тикета 07.
- [ ] Тесты аренды и смещений — на Postgres без брокера: fencing устаревшей ноды, переход
      аренды, сброс на earliest.
- [ ] `DEBT.md`, «Kafka — адаптер только на запись» — снята; `@moduledoc Core.Mq.Kafka`,
      таблица клиентов `README.md`, `10-architecture.md`, ярус потребителя
      `app/14-events-outbox.md` и `CHANGELOG.md` обновлены. Модель сообщения — в «Ломающие
      изменения контракта»: `body` с `nil`, байтовый `Mq.Key`, `position`; миграция таблицы
      смещений — там же.
