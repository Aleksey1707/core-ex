defmodule Core.Mq.Kafka do
  @moduledoc """
  Адаптер Kafka для `Core.Mq`.

  Клиент `:klife` объявлен в библиотеке `optional: true` (`10-architecture.md`):
  `Kafka.Writer` компилируется только у потребителей, добавивших его в свои `deps`.
  """

  @doc """
  Проверить, что клиент `:klife` присутствует и адаптер собран с ним.

  Звать из `start/2` приложения-потребителя, если оно использует `Kafka.Writer` —
  тогда проблема всплывает понятной ошибкой при старте, а не `UndefinedFunctionError`
  на первом вызове `put`/`put_many` (по образцу `Core.Security.Secret.ensure_configured!/0`).
  Различает два случая: клиента нет в сборке вовсе, и клиент есть, но библиотека была
  собрана без него и не пересобрана.
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    cond do
      not Code.ensure_loaded?(Klife.Record) ->
        raise ArgumentError,
              "Core.Mq.Kafka: клиент :klife не найден — добавьте {:klife, \"~> 1.2\"} " <>
                "в deps приложения (README)"

      not Code.ensure_loaded?(Core.Mq.Kafka.Writer) ->
        raise ArgumentError,
              "Core.Mq.Kafka: клиент :klife есть, но библиотека собрана без него — " <>
                "пересоберите: mix deps.compile core --force (README)"

      true ->
        :ok
    end
  end
end
