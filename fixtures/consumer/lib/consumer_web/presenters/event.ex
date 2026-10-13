defmodule ConsumerWeb.Presenters.Event do
  @moduledoc "Событие страницы событий с названием и сведениями на wire: предупреждений быть не должно."

  use Core.Web.Event,
    codec: Consumer.Codec.External,
    user_ref: [dump: &ConsumerWeb.Presenters.Event.user_ref/2],
    labels: true

  alias Consumer.Domain.Sales.Account

  def to_map(%Account.Event.Renamed{} = event, refs) do
    %{id: id, by: by, title: title, details: details} = to_wire(event, refs)
    %{id: id, by: by, title: title, details: details}
  end

  def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
end
