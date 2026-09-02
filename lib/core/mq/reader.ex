defmodule Core.Mq.Reader do
  @moduledoc """
  Контракт чтения сообщений из MQ (без явного commit).
  """

  alias Core.Error
  alias Core.Mq.Message

  @type t :: term()

  @doc """
  Прочитать следующее сообщение.

  `timeout` — `0` (non-blocking), миллисекунды или `:infinity`.
  """
  @callback get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}
end
