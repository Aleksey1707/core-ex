# Кодек событий с намеренными дырами: сценарии «Кодек событий».
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

  use Core.Es.Event.Codec,
    event: Event,
    type: "parcel",
    tags: @tag_by_mod

  # H1: нет clause для Lost.
  @impl true
  def dump_payload(%Event.Sent{payload: payload}, _codec), do: %{"note" => payload.note}

  # H1: нет clause для Lost; H2: Sent возвращает нагрузку чужого модуля.
  @impl true
  def load_payload(Event.Sent, wire, _codec) when is_map(wire),
    do: {:ok, %Account.Event.Renamed.Payload{name: field(wire, :note)}}
end
