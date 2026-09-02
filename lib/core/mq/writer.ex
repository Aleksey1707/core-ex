defmodule Core.Mq.Writer do
  @moduledoc """
  Контракт публикации сообщений в MQ.
  """

  alias Core.Error
  alias Core.Mq.Message

  @type t :: term()

  @callback put(t(), Message.t()) :: :ok | {:error, Error.t()}

  @doc """
  Опубликовать список сообщений строго по порядку.

  При первой ошибке — стоп; `index` — 0-based индекс первого непроуспешного.
  Уже отправленные сообщения не откатываются.
  """
  @callback put_many(t(), [Message.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}
end
