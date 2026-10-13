defmodule ConsumerWeb.Presenters.Event do
  @moduledoc "Название и сведения события на wire рядом с его машинными полями: предупреждений быть не должно."

  use Core.Web.Labels,
    codec: Consumer.Codec.External,
    user_ref: [dump: &ConsumerWeb.Presenters.Event.user_ref/2]

  alias Consumer.Codec.External, as: OutCodec
  alias Consumer.Domain.Sales.Account

  def to_map(%Account.Event.Renamed{} = event, refs) do
    %{title: title, details: details} = to_wire(event, refs)
    %{id: OutCodec.dump(event.id), title: title, details: details}
  end

  def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
end
