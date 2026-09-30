defmodule Core.Mq.Kafka do
  @moduledoc """
  Адаптер Kafka для `Core.Mq`.

  Клиент `:brod` объявлен в библиотеке `optional: true` (`10-architecture.md`):
  `Kafka.Writer` и `Kafka.Reader` компилируются только у потребителей, добавивших его в свои
  `deps`. Клиента — `:brod.start_link_client/3` с `auto_start_producers: true` — стартует
  app-слой в своём дереве, адаптеру приходит его id. Обязательная нативная зависимость
  клиента — `crc32cer` (NIF); кодеки сжатия (`snappyer`, `lz4b`, `ezstd`) — по выбору
  потребителя. Раскладка ключа по партициям — `Core.Mq.Kafka.Partitioner`, как у
  Java-клиентов (ADR-0034).

  `Kafka.Reader` — `Mq.ReaderReliable` без consumer group: смещения и аренда топика — в
  таблицах БД потребителя (`Core.Mq.Kafka.Migration`), поэтому `Core.PubSub.MqSubscriberReliable`
  читает Kafka на любом кластере ≥ 0.11, в том числе без KIP-848 (ADR-0033).
  """

  alias Core.Mq

  @doc """
  Проверить, что клиент `:brod` присутствует и адаптер собран с ним.

  Звать из `start/2` приложения-потребителя, если оно использует `Kafka.Writer` или
  `Kafka.Reader` — тогда проблема всплывает понятной ошибкой при старте, а не
  `UndefinedFunctionError` на первом вызове (по образцу `Core.Security.Secret.ensure_configured!/0`).
  Различает два случая: клиента нет в сборке вовсе, и клиент есть, но библиотека была
  собрана без него и не пересобрана; второе проверяется по writer'у и по читателю.
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    Enum.each([Core.Mq.Kafka.Writer, Core.Mq.Kafka.Reader], fn adapter ->
      Mq.Client.ensure_available!(
        label: "Core.Mq.Kafka",
        client: :brod,
        adapter: adapter,
        dep: :brod,
        requirement: "~> 4.7"
      )
    end)
  end
end
