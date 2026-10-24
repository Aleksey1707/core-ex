defmodule Core.EsFixture.Account.Event.Codec do
  @moduledoc "Кодек событий счёта (плагин фасадов `Core.CodecFixture.*`)."

  alias Core.Es
  alias Core.EsFixture.Account.Event

  @tag_by_mod %{
    Event.Opened => "account.opened",
    Event.Renamed => "account.renamed",
    Event.HolderSet => "account.holder_set",
    Event.Frozen => "account.frozen",
    Event.Closed => "account.closed",
    Event.Verified => "account.verified"
  }
  @upcasts %{
    "account.opened.v1" => "account.opened.v2",
    "account.opened.v2" => "account.opened"
  }

  use Es.Event.Codec,
    family: Event,
    type: "account",
    tags: @tag_by_mod,
    upcasts: @upcasts

  @doc "Нагрузка записанного `Opened` старого тега → нагрузка следующего тега цепочки."
  @spec upcast(String.t(), Es.Event.Codec.wire()) :: wire_payload()

  @impl true
  def upcast("account.opened.v1", envelope),
    do: %{"caption" => field(field(envelope, :payload), :title)}

  def upcast("account.opened.v2", envelope),
    do: %{"name" => field(field(envelope, :payload), :caption)}
end
