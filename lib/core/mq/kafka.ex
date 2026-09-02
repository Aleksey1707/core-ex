defmodule Core.Mq.Kafka do
  @moduledoc """
  Адаптер Kafka для `Core.Mq`.

  Клиент `:klife` объявлен в библиотеке `optional: true` (`10-architecture.md`):
  `Kafka.Writer` компилируется только у потребителей, добавивших его в свои `deps`.
  """

  @doc """
  Проверить, что клиент `:klife` присутствует в сборке.

  Звать из `start/2` приложения-потребителя, если оно использует `Kafka.Writer` —
  тогда отсутствие клиента даёт понятную ошибку при старте, а не `UndefinedFunctionError`
  на первом вызове `put`/`put_many` (по образцу
  `Core.Security.Secret.ensure_configured!/0`).
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    if Code.ensure_loaded?(Core.Mq.Kafka.Writer) do
      :ok
    else
      raise ArgumentError,
            "Core.Mq.Kafka: клиент :klife не найден — добавьте {:klife, \"~> 1.2\"} " <>
              "в deps приложения (README)"
    end
  end
end
