# 07: Адаптер Kafka на `brod`

**What to build:** потребитель публикует в Kafka через `Kafka.Writer` поверх клиента `:brod`
вместо `:klife`: зависимость, handle и конфигурация подключения меняются, поведение `put` /
`put_many` для потребителя — прежнее. Сообщение с тем же ключом попадает в ту же партицию, что и
раньше, и что у Java-клиентов.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

**Spec:** [Чтение из Kafka](../spec.md)

**ADR:** [0034 — адаптер Kafka на `brod`](../../../docs/adr/0034-kafka-adapter-on-brod.md)

## Клиент

- [ ] `mix.exs`: `{:brod, "~> 4.7", optional: true}` вместо `:klife`; `mix.lock` без `:klife` и
      `:klife_protocol`; `no_warn_undefined` — по новым модулям.
- [ ] `Core.Mq.Kafka.ensure_available!/0` проверяет `:brod` (`dep:`, `client:`, `requirement:`).

## Writer

- [ ] Handle `Kafka.Writer` — id клиента `:brod` (атом), который стартует app-слой; публикация —
      `brod:produce_sync/5`, строго по порядку, стоп на первой ошибке (как сейчас).
- [ ] Партиционер murmur2, совместимый с `DefaultPartitioner` Kafka: модуль в `Core.Mq.Kafka`,
      тест на эталонных значениях Java-клиента; без ключа — случайная партиция.
- [ ] Заголовки — список пар `{key, value}`; ключ — байты `Mq.Key`.
- [ ] `body: ""` — `{:error, _}` до отправки: `:brod` пишет пустое значение как null, и сообщение
      стало бы tombstone, молча удаляющим ключ компактного топика (ADR-0034).
- [ ] `detail` ошибки `:kafka_publish_failed` — нормализация причин `:brod` (неизвестный топик,
      код брокера, прочее) вместо причин `:klife`; исключение клиента не роняет вызывающего.
- [ ] Компилируется только при `:brod` в `deps`; `make compile-no-optional` проходит.

## Проверки и документы

- [ ] Тесты с живым брокером — тег `:kafka`, исключённый по умолчанию; `apache/kafka:4.1`
      (KRaft, одна нода) в `deploy/infra/compose.yml` рядом с RabbitMQ, образ подменяется
      переменной `KAFKA_IMAGE` (прогон на линии без KIP-848); `make test-kafka` по образцу
      `test-stream`. Тесты writer'а на поддельном клиенте переписаны: ключ → партиция, порядок,
      ошибка на неизвестном топике.
- [ ] `README.md` (таблица клиентов и нативные зависимости: `crc32cer`, сжатие — по выбору),
      `10-architecture.md` (`%Klife.Record{}`, `use Klife.Client` в app-слое), `@moduledoc`
      `Core.Mq.Kafka` и `Kafka.Writer`.
- [ ] `CHANGELOG.md`, «Ломающие изменения контракта»: `:klife` → `:brod` в `deps`, handle — модуль
      `use Klife.Client` → id клиента `:brod` со стартом клиента в дереве потребителя (было →
      стало), нет идемпотентного продюсера — возможны дубли при повторе отправки, отказ на
      `body: ""`.
