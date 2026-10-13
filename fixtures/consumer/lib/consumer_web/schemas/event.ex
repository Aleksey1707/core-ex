defmodule ConsumerWeb.Schemas.Event do
  @moduledoc "Событие страницы событий на wire: предупреждений быть не должно."

  use Core.Web.Event,
    codec: Consumer.Codec.External,
    user_ref: [dump: &ConsumerWeb.Schemas.Event.user_ref/2]

  alias Consumer.Domain.Sales.Account

  def to_map(%Account.Event.Renamed{} = event, refs), do: %{to_wire(event, refs) | payload: nil}

  def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
end
