defmodule Consumer.S.BadProjection do
  @moduledoc "Проекция без clause `project/1` для `Closed` и с опечаткой в суженной нагрузке."

  alias Consumer.Account

  # G1 — нет clause `project/1` для `Closed`: проверка полноты на строке `use`
  # expect: incompatible types given to project/1
  use Core.Es.Projection,
    name: "consumer_bad",
    events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed]

  @impl true
  def project(%Account.Event.Opened{payload: %Account.Event.Opened.Payload{} = payload}),
    do: name(payload.name)

  # G3b — опечатка в поле нагрузки, суженной `%Payload{}`
  def project(%Account.Event.Renamed{payload: %Account.Event.Renamed.Payload{} = payload}),
    # expect: unknown key .nmae
    do: name(payload.nmae)

  @impl true
  def clear, do: :ok

  defp name(_name), do: :ok
end

defmodule Consumer.S.BadProjectionPayload do
  @moduledoc "Проекция с опечаткой в поле нагрузки, не суженной паттерном."

  alias Consumer.Account

  # G3a — опечатка в поле нагрузки без паттерна `%Payload{}`: при определении молчит, опора G3c
  # expect: incompatible types given to project/1
  use Core.Es.Projection,
    name: "consumer_bad_payload",
    events: [Account.Event.Opened]

  @impl true
  def project(%Account.Event.Opened{payload: payload}), do: name(payload.nmae)

  @impl true
  def clear, do: :ok

  defp name(_name), do: :ok
end

defmodule Consumer.S.Projection do
  @moduledoc "Прямые вызовы `project/1`."

  alias Consumer.Account
  alias Consumer.S.BadProjection
  alias Consumer.S.BadProjectionPayload
  alias Consumer.UserID
  alias Core.Es
  alias Core.Version

  # G1d — прямой `project/1` с событием без clause
  def g1_direct_missing_clause(%Account.Event.Closed{} = event),
    # expect: incompatible types given to Consumer.S.BadProjection.project/1
    do: BadProjection.project(event)

  # G3c — прямой `project/1` с событием из конструктора при опечатке G3a
  def g3c_direct_payload_typo(
        %Account.Event.Opened.Payload{} = payload,
        %Account.ID{} = id,
        %UserID{} = by,
        %Es.Event.At{} = at
      ) do
    event = Account.Event.Opened.new(payload, id, Version.new(), by, at)
    # expect: incompatible types given to Consumer.S.BadProjectionPayload.project/1
    BadProjectionPayload.project(event)
  end
end
