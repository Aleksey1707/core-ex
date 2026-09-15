defmodule Core.Es.Store.Schema do
  @moduledoc """
  Ecto-схема `es_events` (`Core.Es.Migration`) и перевод строки в конверт события.

  Колонок глобальной позиции — `xid` и `number` — в схеме нет: их значения ставит база при
  записи.
  """

  use Ecto.Schema

  alias Core.Es

  defmodule Payload do
    @moduledoc """
    Ecto-тип нагрузки события: jsonb любого JSON-значения.

    Штатный `:map` не принимает нагрузку-список или скаляр, а кодек событий их допускает.
    """
    use Ecto.Type

    @doc false
    @spec type() :: :map

    @impl true
    def type, do: :map

    @doc false
    @spec cast(term()) :: {:ok, term()}

    @impl true
    def cast(value), do: {:ok, value}

    @doc false
    @spec load(term()) :: {:ok, term()}

    @impl true
    def load(value), do: {:ok, value}

    @doc false
    @spec dump(term()) :: {:ok, term()}

    @impl true
    def dump(value), do: {:ok, value}
  end

  @primary_key false

  schema "es_events" do
    field :aggregate_type, :string
    field :aggregate_id, :binary_id
    field :aggregate_version, :integer
    field :event_id, :binary_id
    field :tag, :string
    field :payload, Payload
    field :by_id, :binary_id
    field :at, :utc_datetime
  end

  @type t :: %__MODULE__{}

  @doc "Строка → конверт события (`Core.Es.Event.Codec.from_fields/1`)."
  @spec to_wire(t()) :: Es.Event.Codec.wire()

  def to_wire(%__MODULE__{} = row) do
    Es.Event.Codec.from_fields(%{
      id: row.event_id,
      type: row.tag,
      payload: row.payload,
      aggregate_id: row.aggregate_id,
      aggregate_version: row.aggregate_version,
      at: row.at,
      by: row.by_id
    })
  end
end
