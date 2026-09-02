defmodule Core.PubSub do
  @moduledoc """
  Контракты доменного pub/sub.

  Skip — через `{:skip, reason}`, не через исключения.
  """

  alias Core.Context
  alias Core.Error

  @type skip_reason :: term()
  @type handler_result :: :ok | {:skip, skip_reason()} | {:error, Error.t()}

  defmodule Publisher do
    @moduledoc """
    Контракт публикации сообщения.
    """

    alias Core.Context
    alias Core.Error

    @type t :: term()
    @type message :: term()
    @type metadata :: term()

    @callback publish(t(), message(), metadata(), Context.t()) :: :ok | {:error, Error.t()}
  end

  defmodule Subscriber do
    @moduledoc """
    Контракт подписки на сообщения.
    """

    alias Core.Context
    alias Core.Error

    @type t :: term()
    @type data :: term()

    @callback subscribe(t(), data(), Context.t()) :: :ok | {:error, Error.t()}
    @callback unsubscribe(t(), Context.t()) :: :ok | {:error, Error.t()}
  end
end
