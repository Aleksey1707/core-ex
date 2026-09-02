defmodule Core.PubSub.MqPublisher do
  @moduledoc """
  `PubSub.Publisher` → прямая публикация через `Mq.Writer`.
  """

  @behaviour Core.PubSub.Publisher

  alias Core.Context
  alias Core.Error
  alias Core.Helper.Transact
  alias Core.Mq.Message

  defstruct [:writer_module, :writer, :to_message]

  @type message :: term()
  @type metadata :: term()
  @type to_message :: (message(), metadata() -> {:ok, Message.t()} | {:error, Error.t()})

  @type t :: %__MODULE__{
          writer_module: module(),
          writer: term(),
          to_message: to_message()
        }

  @doc "Создать publisher."
  @spec new(module(), term(), to_message()) :: t()

  def new(writer_module, writer, to_message)
      when is_atom(writer_module) and is_function(to_message, 2) do
    %__MODULE__{writer_module: writer_module, writer: writer, to_message: to_message}
  end

  @doc "Опубликовать сообщение напрямую в MQ."
  @spec publish(t(), message(), metadata(), Context.t()) :: :ok | {:error, Error.t()}

  @impl true
  def publish(%__MODULE__{} = publisher, message, metadata, %Context{}) do
    :ok = Transact.warn_in_transaction("публикация в MQ")

    with {:ok, mq_message} <- publisher.to_message.(message, metadata) do
      publisher.writer_module.put(publisher.writer, mq_message)
    end
  end
end
