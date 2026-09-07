defmodule Core.Outbox.Delivery do
  @moduledoc """
  Контракт доставки записи outbox наружу.

  `publish_many/2` — строго по порядку списка; при первой ошибке стоп
  (`{:error, index, error}`, index 0-based).

  `t()` — handle реализации, а не её модуль: модуль передаётся отдельно (`Poller` берёт
  его из опции `:delivery_module`), как `Delivery.Mq.new/2` принимает `writer_module`
  рядом с handle writer'а. Выводить модуль из `__struct__` handle MUST NOT — контракт
  структуры не требует.
  """

  alias Core.Error
  alias Core.Outbox.Record

  @type t :: term()

  @callback publish(t(), Record.t()) :: :ok | {:error, Error.t()}

  @callback publish_many(t(), [Record.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}
end
