defmodule Core.Outbox.Delivery do
  @moduledoc """
  Контракт доставки записи outbox наружу.

  `publish_many/2` — строго по порядку списка; при первой ошибке стоп
  (`{:error, index, error}`, index 0-based).
  """

  alias Core.Error
  alias Core.Outbox.Record

  @type t :: term()

  @callback publish(t(), Record.t()) :: :ok | {:error, Error.t()}

  @callback publish_many(t(), [Record.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}
end
