defmodule Consumer.Domain.Sales.Account.Event.Codec do
  @moduledoc "Кодек с событиями с нагрузкой и без, с `upcasts:`; нагрузку `Opened` кодирует ручной плагин её типа."

  alias Consumer.Domain.Sales.Account.Event

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
  def upcast("account.opened.v1", envelope),
    do: %{"name" => field(field(envelope, :payload), :title)}
end
