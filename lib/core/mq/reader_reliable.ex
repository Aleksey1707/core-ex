defmodule Core.Mq.ReaderReliable do
  @moduledoc """
  Контракт надёжного чтения: `commit` фиксирует offset/cursor.
  """

  alias Core.Error
  alias Core.Mq.Message

  @type t :: term()

  @callback get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}
  @callback commit(t()) :: :ok | {:error, Error.t()}
end
