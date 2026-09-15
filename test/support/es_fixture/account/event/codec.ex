defmodule Core.EsFixture.Account.Event.Codec do
  @moduledoc "Кодек событий счёта (плагин фасадов `Core.CodecFixture.*`)."

  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Event

  @tag_by_mod %{
    Event.Opened => "account.opened",
    Event.Renamed => "account.renamed",
    Event.Frozen => "account.frozen",
    Event.Closed => "account.closed",
    Event.Verified => "account.verified"
  }
  @upcasts %{
    "account.opened.v1" => "account.opened.v2",
    "account.opened.v2" => "account.opened"
  }

  use Es.Event.Codec,
    event: Event,
    type: "account",
    tags: @tag_by_mod,
    upcasts: @upcasts

  @doc "Нагрузка события → wire."
  @spec dump_payload(Event.Opened.t() | Event.Renamed.t(), module()) :: map()

  @impl true
  def dump_payload(%Event.Opened{payload: payload}, codec),
    do: %{"name" => codec.dump(payload.name)}

  def dump_payload(%Event.Renamed{payload: payload}, codec),
    do: %{"name" => codec.dump(payload.name)}

  @doc "Wire-нагрузка → `%Payload{}`."
  @spec load_payload(module(), term(), module()) ::
          {:ok, Event.Opened.Payload.t() | Event.Renamed.Payload.t()} | {:error, Core.Error.t()}

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

  @doc "Нагрузка записанного `Opened` старого тега → нагрузка следующего тега цепочки."
  @spec upcast(String.t(), Es.Event.Codec.wire()) :: wire_payload()

  @impl true
  def upcast("account.opened.v1", envelope),
    do: %{"caption" => field(field(envelope, :payload), :title)}

  def upcast("account.opened.v2", envelope),
    do: %{"name" => field(field(envelope, :payload), :caption)}
end
