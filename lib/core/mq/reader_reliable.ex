defmodule Core.Mq.ReaderReliable do
  @moduledoc """
  Контракт надёжного чтения: `commit` фиксирует offset/cursor.

  Единственный контракт чтения в библиотеке: `Core.PubSub.MqSubscriberReliable` работает
  только с ним, и подписчику без commit'а подключиться некуда. Как и у `Mq.Writer`,
  представление на проводе задаёт адаптер (`10-architecture.md`).
  """

  alias Core.Error
  alias Core.Mq.Message

  @type t :: term()

  @callback get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}
  @callback commit(t()) :: :ok | {:error, Error.t()}
end
