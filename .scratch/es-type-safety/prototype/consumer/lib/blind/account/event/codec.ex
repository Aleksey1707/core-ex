defmodule Blind.Account.Event.Codec do
  alias Blind.Account
  alias Blind.Account.Event

  @tag_by_mod %{
    Event.Opened => "account.opened",
    Event.Renamed => "account.renamed",
    Event.Frozen => "account.frozen",
    Event.Closed => "account.closed"
  }
  @upcasts %{"account.opened.v1" => "account.opened"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "account",
    tags: @tag_by_mod,
    upcasts: @upcasts

  @impl true
  def dump_payload(%Event.Opened{payload: payload}, codec),
    do: %{"name" => codec.dump(payload.name)}

  def dump_payload(%Event.Renamed{payload: payload}, codec),
    do: %{"name" => codec.dump(payload.name)}

  @impl true
  def load_payload(Event.Opened, wire, codec) do
    with {:ok, name} <- codec.load(Account.Name, field(wire, :name)) do
      {:ok, Event.Opened.Payload.new(name)}
    end
  end

  def load_payload(Event.Renamed, wire, codec) do
    with {:ok, name} <- codec.load(Account.Name, field(wire, :name)) do
      {:ok, Event.Renamed.Payload.new(name)}
    end
  end

  @impl true
  def upcast("account.opened.v1", envelope),
    do: %{"name" => field(field(envelope, :payload), :title)}
end
