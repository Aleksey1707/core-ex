defmodule Core.Mq.Kafka do
  @moduledoc """
  Адаптер Kafka для `Core.Mq`.

  Клиент `:brod` объявлен в библиотеке `optional: true` (`10-architecture.md`):
  `Kafka.Writer` компилируется только у потребителей, добавивших его в свои `deps`.
  Клиента — `:brod.start_link_client/3` с `auto_start_producers: true` — стартует app-слой
  в своём дереве, адаптеру приходит его id. Обязательная нативная зависимость клиента —
  `crc32cer` (NIF); кодеки сжатия (`snappyer`, `lz4b`, `ezstd`) — по выбору потребителя.
  Раскладка ключа по партициям — `Core.Mq.Kafka.Partitioner`, как у Java-клиентов (ADR-0034).

  Адаптер — **только на запись**: реализации `Mq.ReaderReliable` для Kafka нет, поэтому
  `Core.PubSub.MqSubscriberReliable` и путь DLQ работают только поверх RabbitMQ Stream.
  Outbox публиковать в Kafka может, читать опубликованное средствами библиотеки — нет
  (`DEBT.md`).
  """

  alias Core.Mq

  @doc """
  Проверить, что клиент `:brod` присутствует и адаптер собран с ним.

  Звать из `start/2` приложения-потребителя, если оно использует `Kafka.Writer` —
  тогда проблема всплывает понятной ошибкой при старте, а не `UndefinedFunctionError`
  на первом вызове `put`/`put_many` (по образцу `Core.Security.Secret.ensure_configured!/0`).
  Различает два случая: клиента нет в сборке вовсе, и клиент есть, но библиотека была
  собрана без него и не пересобрана.
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    Mq.Client.ensure_available!(
      label: "Core.Mq.Kafka",
      client: :brod,
      adapter: Core.Mq.Kafka.Writer,
      dep: :brod,
      requirement: "~> 4.7"
    )
  end
end
