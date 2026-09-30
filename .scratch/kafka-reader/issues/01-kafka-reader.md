# 01: `Mq.ReaderReliable` для Kafka

**What to build:** потребитель подписывается на топики Kafka тем же `MqSubscriberReliable`, что и
на RabbitMQ Stream: `get` отдаёт следующее сообщение с ключом, заголовками, телом как есть и
позицией источника, `commit` фиксирует смещение, а после рестарта или смены ноды-владельца чтение
продолжается с зафиксированного смещения. Подписчик, у которого смещения ещё нет, читает топик с
начала. Работает на любой Kafka ≥ 3.1, в том числе без KIP-848.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

**Spec:** [Чтение из Kafka](../spec.md)

**ADR:** [0032 — `Mq.Message` моделирует запись чужого топика](../../../docs/adr/0032-mq-message-models-foreign-topic-record.md),
[0033 — читатель Kafka без consumer group](../../../docs/adr/0033-kafka-reader-without-consumer-group.md)

## Модель сообщения (ADR-0032)

- [ ] `Mq.Key` — собственный примитив над непустым `binary()` без верхнего предела и без
      UTF-8; модуль и API (`new/1`, `value/1`, struct) прежние.
- [ ] `Mq.HeaderKey` — любая непустая строка UTF-8 в нижнем регистре; повтор имени — последнее
      значение, null-значение — `""`.
- [ ] `Message.body :: binary() | nil`: `nil` — tombstone (`:klife` отдаёт null как `nil`);
      `Kafka.Writer` публикует его как tombstone.
- [ ] `Mq.Position` (`partition: non_neg_integer() | nil`, `offset: non_neg_integer()`) и
      `Message.position :: Mq.Position.t() | nil`; `Stream.Reader` заполняет смещение при
      `partition: nil`.
- [ ] `Stream.Codec`: ключ или значение заголовка не в UTF-8 и `nil`-тело — `{:error, _}`.

## Читатель (ADR-0033)

- [ ] `Core.Mq.Kafka.Reader` — GenServer, `Mq.ReaderReliable` поверх прямого `Client.fetch/4`
      `:klife`, без consumer group. Опции: `client:` (модуль `use Klife.Client`, как handle
      `Kafka.Writer`), `topic:`, `subscriber_name:`, `repo:`; стартовая позиция без смещения —
      опция, по умолчанию earliest.
- [ ] Все партиции топика обходятся по кругу, одно сообщение в работе на читатель; новые
      партиции подхватываются из метаданных. Последовательность и head-of-line (повторяемое
      сообщение держит весь топик) — в `@moduledoc`.
- [ ] `get` без `commit` предыдущего отдаёт то же сообщение (повтор, как у `Stream.Reader`).
- [ ] Смещения — таблица БД потребителя, ключ `(subscriber_name, topic, partition)`, следующее
      смещение и время записи; миграция — хелпером библиотеки по образцу `Core.Outbox.Migration`.
      `commit` — синхронный upsert.
- [ ] Одна активная нода на топик: аренда строкой с fencing-токеном по образцу поллера outbox.
      `commit` проверяет токен, у устаревшей ноды — `{:error, _}`; нода без аренды отдаёт
      `:empty`; потеря аренды сбрасывает буфер и сообщение в работе.
- [ ] Earliest / latest — `ListOffsets`, число партиций — `Klife.MetadataCache`: внутренний API
      `:klife`, вызовы в одном модуле адаптера; `{:klife, "~> 1.2.0"}` в `mix.exs`.
- [ ] `{:error, 1}` (`OFFSET_OUT_OF_RANGE`) — переход на earliest, `error` в лог, счётчик сброса
      в telemetry.
- [ ] Смена лидера (коды 6 / 74 / 75 / 100 / 103), `:timeout`, `:unexpected_resp` — повтор с
      backoff внутри читателя, `get` — `:empty`, `warning` с ограниченной частотой. Неизвестный
      топик (`:klife` бросает `MatchError`) — ошибка, а не падение читателя.
- [ ] Компилируется только при клиенте в `deps` (как `Kafka.Writer`);
      `Core.Mq.Kafka.ensure_available!/0` различает читателя и проверяет, что внутренние функции
      `:klife` на месте.
- [ ] Wire-формат: тело — байты Kafka без конверта (ADR-0004, «Wire-формат принадлежит адаптеру»).

## Проверки и документы

- [ ] Тесты с живым брокером — тег `:kafka`, исключённый по умолчанию; `apache/kafka:4.1`
      (KRaft, одна нода) в `deploy/infra/compose.yml` рядом с RabbitMQ, образ подменяется
      переменной `KAFKA_IMAGE` (прогон на линии 3.x без KIP-848); `make test-kafka` по образцу
      `test-stream`.
- [ ] Тесты аренды и смещений — на Postgres без брокера: fencing устаревшей ноды, переход
      аренды, сброс на earliest.
- [ ] `DEBT.md`, «Kafka — адаптер только на запись» — снята; `@moduledoc Core.Mq.Kafka`,
      таблица клиентов `README.md`, `10-architecture.md`, ярус потребителя
      `app/14-events-outbox.md` и `CHANGELOG.md` обновлены. Модель сообщения — в «Ломающие
      изменения контракта»: `body` с `nil`, байтовый `Mq.Key`, `position`; сужение `:klife` до
      `~> 1.2.0` и миграция таблицы смещений — там же.
