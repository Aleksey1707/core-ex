defmodule Core.Mq.Stream do
  @moduledoc """
  Адаптеры RabbitMQ Stream для `Core.Mq`.

  Клиент `:rabbitmq_stream` объявлен в библиотеке `optional: true`
  (`10-architecture.md`): `Stream.Connection` и `Stream.Reader` компилируются только
  у потребителей, добавивших его в свои `deps`.
  """

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
    cond do
      not Code.ensure_loaded?(RabbitMQStream.Connection) ->
        raise ArgumentError,
              "Core.Mq.Stream: клиент :rabbitmq_stream не найден — добавьте " <>
                "{:rabbitmq_stream, \"~> 0.4\"} в deps приложения (README)"

      not Code.ensure_loaded?(Core.Mq.Stream.Connection) ->
        raise ArgumentError,
              "Core.Mq.Stream: клиент :rabbitmq_stream есть, но библиотека собрана без него — " <>
                "пересоберите: mix deps.compile core --force (README)"

      true ->
        :ok
    end
  end
end
