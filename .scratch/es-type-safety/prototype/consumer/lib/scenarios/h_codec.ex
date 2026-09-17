defmodule Blind.Parcel.ID do
  use Core.Prim.UUID,
    name: "Посылка",
    version: 7
end

defmodule Blind.Parcel.Event do
  alias Blind.Parcel
  alias Blind.UserID

  defmodule Sent do
    defmodule Payload do
      @enforce_keys ~w(note)a
      defstruct @enforce_keys

      def new(note) when is_binary(note), do: %__MODULE__{note: note}
    end

    use Core.Es.Event,
      aggregate_id: Parcel.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Lost do
    defmodule Payload do
      @enforce_keys ~w(note)a
      defstruct @enforce_keys

      def new(note) when is_binary(note), do: %__MODULE__{note: note}
    end

    use Core.Es.Event,
      aggregate_id: Parcel.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Returned do
    use Core.Es.Event,
      aggregate_id: Parcel.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Sent.t() | Lost.t() | Returned.t()
end

defmodule Blind.Parcel.Event.Codec do
  alias Blind.Account
  alias Blind.Parcel.Event

  @tag_by_mod %{
    Event.Sent => "parcel.sent",
    Event.Lost => "parcel.lost",
    Event.Returned => "parcel.returned"
  }

  # H1 — нет clause dump_payload/load_payload для Lost; H2 — Sent грузит литерал чужой нагрузки
  # expect: incompatible types given to dump_payload/2
  # expect: incompatible types given to load_payload/3
  # expect: the following clause will never match
  use Core.Es.Event.Codec,
    event: Event,
    type: "parcel",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%Event.Sent{payload: payload}, _codec), do: %{"note" => payload.note}

  @impl true
  def load_payload(Event.Sent, wire, _codec) when is_map(wire),
    do: {:ok, %Account.Event.Renamed.Payload{name: field(wire, :note)}}
end

defmodule Blind.Parcel.Event.CodecNew do
  alias Blind.Account
  alias Blind.Parcel.Event

  @tag_by_mod %{
    Event.Sent => "parcel_new.sent",
    Event.Lost => "parcel_new.lost",
    Event.Returned => "parcel_new.returned"
  }

  # H2n — Sent грузит чужую нагрузку через Payload.new/1 того же проекта
  # expect: the following clause will never match
  use Core.Es.Event.Codec,
    event: Event,
    type: "parcel_new",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%Event.Sent{payload: payload}, _codec), do: %{"note" => payload.note}
  def dump_payload(%Event.Lost{payload: payload}, _codec), do: %{"note" => payload.note}

  @impl true
  def load_payload(Event.Sent, wire, codec) when is_map(wire) do
    with {:ok, name} <- codec.load(Account.Name, field(wire, :note)) do
      {:ok, Account.Event.Renamed.Payload.new(name)}
    end
  end

  def load_payload(Event.Lost, wire, _codec) when is_map(wire),
    do: {:ok, Event.Lost.Payload.new(field(wire, :note))}
end
