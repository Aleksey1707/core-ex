defmodule Blind.BadProjection do
  alias Blind.Account
  alias Blind.Order

  use Core.Es.Projection,
    name: "blind_bad",
    events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed]

  # G3a — опечатка в поле нагрузки
  @impl true
  def project(%Account.Event.Opened{payload: payload}), do: store(payload.nmae)

  # G3b — опечатка в поле нагрузки, нагрузка сопоставлена с %Payload{}
  def project(%Account.Event.Renamed{payload: %Account.Event.Renamed.Payload{} = payload}),
    do: store(payload.nmae)

  # G2 — clause для события не из events:
  def project(%Order.Event.Placed{}), do: :ok

  # G1 — нет clause для Account.Event.Closed

  @impl true
  def clear, do: :ok

  defp store(_name), do: :ok
end

defmodule Blind.S.Projection do
  alias Blind.Account
  alias Blind.BadProjection
  alias Blind.Order

  # G1 прямым вызовом
  def g1_direct_missing(%Account.Event.Closed{} = event), do: BadProjection.project(event)

  # G3c — прямой вызов project/1 с событием, собранным конструктором
  def g3c_direct_typo_clause(
        %Account.Event.Opened.Payload{} = payload,
        %Account.ID{} = id,
        %Blind.UserID{} = by,
        %Core.Es.Event.At{} = at
      ) do
    BadProjection.project(Account.Event.Opened.new(payload, id, Core.Version.new(), by, at))
  end

  # G4 — await: чужой ID и агрегат не из events:
  def g4_await_foreign_id(%Order.ID{} = id), do: Core.Es.Projection.await(Blind.Projection, Account, id, 100)

  def g4b_await_foreign_aggregate(%Order.ID{} = id),
    do: Core.Es.Projection.await(Blind.Projection, Order, id, 100)

  def g4c_await_case(%Account.ID{} = id) do
    case Core.Es.Projection.await(Blind.Projection, Account, id, 100) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} -> :error
    end
  end
end
