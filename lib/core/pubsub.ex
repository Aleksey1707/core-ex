defmodule Core.PubSub do
  @moduledoc """
  Контракты доменного pub/sub.

  Skip — через `{:skip, reason}`, не через исключения. Отказ без повторов — `{:reject, error}`:
  сообщение не обработать никогда (тело не разбирается, запись нарушает инвариант), и повтор
  не поможет.
  """

  alias Core.Context
  alias Core.Error
  alias Core.Result

  @type skip_reason :: term()
  @type handler_result :: :ok | {:skip, skip_reason()} | {:reject, Error.t()} | {:error, Error.t()}

  @typedoc "Исход разбора сообщения: `{:reject, _}` — ошибка разбора, которую повтор не исправит."
  @type decode_result(message) :: {:ok, message} | {:reject, Error.t()} | {:error, Error.t()}

  defmodule Publisher do
    @moduledoc """
    Контракт публикации сообщения.
    """

    alias Core.Context
    alias Core.Error

    @type t :: term()
    @type message :: term()
    @type metadata :: term()

    @callback publish(t(), message(), metadata(), Context.t()) :: Result.unit()
  end

  defmodule Subscriber do
    @moduledoc """
    Контракт подписки на сообщения.
    """

    alias Core.Context
    alias Core.Error

    @type t :: term()
    @type data :: term()

    @callback subscribe(t(), data(), Context.t()) :: Result.unit()
    @callback unsubscribe(t(), Context.t()) :: Result.unit()
  end
end
