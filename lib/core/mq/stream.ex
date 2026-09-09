defmodule Core.Mq.Stream do
  @moduledoc """
  Адаптеры RabbitMQ Stream для `Core.Mq`.

  Клиент `:rabbitmq_stream` объявлен в библиотеке `optional: true`
  (`10-architecture.md`): `Stream.Connection` и `Stream.Reader` компилируются только
  у потребителей, добавивших его в свои `deps`.
  """

  alias Core.Mq

  @doc """
  Проверить, что клиент `:rabbitmq_stream` присутствует и адаптер собран с ним.

  Звать из `start/2` приложения-потребителя, если оно поднимает `Stream.Connection` —
  тогда проблема всплывает понятной ошибкой при старте, а не `UndefinedFunctionError`
  где-то в глубине supervisor-дерева на первом вызове (по образцу
  `Core.Security.Secret.ensure_configured!/0`). Различает два случая: клиента нет
  в сборке вовсе, и клиент есть, но библиотека была собрана без него и не пересобрана.
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    Mq.Client.ensure_available!(
      label: "Core.Mq.Stream",
      client: RabbitMQStream.Connection,
      adapter: Core.Mq.Stream.Connection,
      dep: :rabbitmq_stream,
      requirement: "~> 0.4"
    )
  end
end
