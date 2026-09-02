defmodule Core.PubSub.OutboxPublisher do
  @moduledoc """
  `PubSub.Publisher` → запись в transactional outbox.
  """

  @behaviour Core.PubSub.Publisher

  alias Core.Context
  alias Core.Error
  alias Core.Outbox.Record

  defstruct [:repo, :to_record]

  @type message :: term()
  @type metadata :: term()
  @type to_record :: (message(), metadata() -> {:ok, Record.t()} | {:error, Error.t()})

  @type t :: %__MODULE__{
          repo: module(),
          to_record: to_record()
        }

  @doc "Создать publisher. `to_record` — message+metadata → outbox Record."
  @spec new(module(), to_record()) :: t()

  def new(repo, to_record) when is_atom(repo) and is_function(to_record, 2) do
    %__MODULE__{repo: repo, to_record: to_record}
  end

  @doc "Опубликовать сообщение через запись в outbox."
  @spec publish(t(), message(), metadata(), Context.t()) :: :ok | {:error, Error.t()}

  @impl true
  def publish(%__MODULE__{} = publisher, message, metadata, %Context{} = context) do
    with {:ok, record} <- publisher.to_record.(message, metadata) do
      publisher.repo.append([record], context)
    end
  end
end
