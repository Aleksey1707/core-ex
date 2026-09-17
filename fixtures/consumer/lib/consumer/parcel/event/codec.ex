defmodule Consumer.Parcel.Event.Codec do
  @moduledoc "Кодек, чей `load_payload/3` никогда не возвращает ошибку; в фасад не входит."

  alias Consumer.Parcel.Event

  @tag_by_mod %{
    Event.Sent => "parcel.sent",
    Event.Lost => "parcel.lost",
    Event.Returned => "parcel.returned"
  }

  use Core.Es.Event.Codec,
    event: Event,
    type: "parcel",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%Event.Sent{payload: %Event.Sent.Payload{} = payload}, _codec),
    do: %{"note" => payload.note}

  def dump_payload(%Event.Lost{payload: %Event.Lost.Payload{} = payload}, _codec),
    do: %{"note" => payload.note}

  @impl true
  def load_payload(Event.Sent, wire, _codec) when is_map(wire),
    do: {:ok, Event.Sent.Payload.new(field(wire, :note))}

  def load_payload(Event.Lost, wire, _codec) when is_map(wire),
    do: {:ok, %Event.Lost.Payload{note: field(wire, :note)}}
end
