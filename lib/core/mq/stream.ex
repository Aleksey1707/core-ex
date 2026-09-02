defmodule Core.Mq.Stream do
  @moduledoc """
  Адаптеры RabbitMQ Stream для `Core.Mq`.

  Клиент `:rabbitmq_stream` объявлен в библиотеке `optional: true`
  (`10-architecture.md`): `Stream.Connection` и `Stream.Reader` компилируются только
  у потребителей, добавивших его в свои `deps`.
  """

  @doc """
  Проверить, что клиент `:rabbitmq_stream` присутствует в сборке.

  Звать из `start/2` приложения-потребителя, если оно поднимает `Stream.Connection` —
  тогда отсутствие клиента даёт понятную ошибку при старте, а не `UndefinedFunctionError`
  где-то в глубине supervisor-дерева на первом вызове (по образцу
  `Core.Security.Secret.ensure_configured!/0`).
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    if Code.ensure_loaded?(Core.Mq.Stream.Connection) do
      :ok
    else
      raise ArgumentError,
            "Core.Mq.Stream: клиент :rabbitmq_stream не найден — добавьте " <>
              "{:rabbitmq_stream, \"~> 0.4\"} в deps приложения (README)"
    end
  end
end
