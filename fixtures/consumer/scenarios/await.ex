defmodule ConsumerTest.Await do
  @moduledoc "`Projection.await/3` и `await/4`: агрегат, ID, версия, результат; ожидание в usecase с `wait:`."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Ping
  alias Consumer.Domain.Sales.Activity.Projection
  alias Core.Error
  alias Core.Version

  # G4 — ID другого агрегата
  def g4_foreign_id(%Order.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    do: Projection.await(Account, id, 100)

  # G4b — агрегат, чьих событий нет в `events:`
  def g4b_foreign_aggregate(%Ping.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    do: Projection.await(Ping, id, 100)

  # G4s — поток субъекта ждётся по `Core.Es.Personal.SubjectID`, а не по ID агрегата-субъекта
  def g4s_subject_by_aggregate_id(%Account.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    do: Projection.await(Core.Es.Personal, id, 100)

  # G4o — прежняя форма: реализация ожидания в библиотеке вместо `await/3` модуля проекции
  # expect: Core.Es.Projection.await/4 is undefined or private
  def g4o_library_await(%Account.ID{} = id), do: Core.Es.Projection.await(Projection, Account, id, 100)

  # G4c — `{:ok, _}` по результату `await`
  def g4c_case_ok(%Account.ID{} = id) do
    case Projection.await(Account, id, 100) do
      :ok -> :ok
      # expect: the following clause will never match
      {:ok, _} -> :ok
      {:error, _error} -> :error
    end
  end

  # G4v — ожидание события версии: ID другого агрегата
  def g4v_foreign_id(%Order.ID{} = id, %Version{} = version),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/4
    do: Projection.await(Account, id, version, 100)

  # G4vi — версия голым целым, а не `%Core.Version{}`
  def g4vi_integer_version(%Account.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/4
    do: Projection.await(Account, id, 2, 100)

  # G4w — usecase заказа с `wait:`: хелпер ожидания скопирован у счёта, и агрегат в `await` — счёт
  def g4w_wait_foreign_aggregate(%Order.ID{} = id, opts),
    do: {:ok, {awaited(id, Keyword.get(opts, :wait, :none)), id}}

  # ---

  defp awaited(%Order.ID{}, :none), do: :accepted

  defp awaited(%Order.ID{} = id, timeout) when is_integer(timeout) do
    # expect: incompatible types given to Consumer.Domain.Sales.Activity.Projection.await/3
    case Projection.await(Account, id, timeout) do
      :ok -> :projected
      {:error, %Error{code: code}} when code in ~w(projection_timeout projection_rebuilding)a -> :accepted
    end
  end
end

defmodule ConsumerTest.Shipment do
  @moduledoc "Владелец потока с ID заказа: соседний поток с общим ID."

  alias Consumer.Domain.Sales.Order

  defstruct id: nil

  @type t :: %__MODULE__{id: Order.ID.t() | nil}
end

defmodule ConsumerTest.Shipment.Event do
  @moduledoc "События отгрузки заказа."

  alias Consumer.Domain.Sales.Order
  alias Consumer.Domain.Sales.Values.UserID
  alias ConsumerTest.Shipment

  use Core.Es.Event.Family,
    aggregate: Shipment,
    aggregate_id: Order.ID,
    by: UserID,
    codec: Shipment.Event.Codec

  @type t :: Shipment.Event.Shipped.t()
end

defmodule ConsumerTest.Shipment.Event.Shipped do
  use Core.Es.Event,
    family: ConsumerTest.Shipment.Event,
    payload: nil
end

defmodule ConsumerTest.Shipment.Event.Codec do
  @moduledoc "Кодек событий отгрузки."

  alias ConsumerTest.Shipment.Event

  use Core.Es.Event.Codec,
    family: Event,
    type: "shipment",
    tags: %{Event.Shipped => "shipment.shipped"}
end

defmodule ConsumerTest.SharedID.Projection do
  @moduledoc "Проекция на событиях двух владельцев потока с общим ID заказа."

  alias Consumer.Domain.Sales.Order
  alias ConsumerTest.Shipment

  use Core.Es.Projection,
    name: "consumer_shared_id",
    events: [Order.Event.Placed, Shipment.Event.Shipped]

  @impl true
  def project(%Order.Event.Placed{}), do: :ok
  def project(%Shipment.Event.Shipped{}), do: :ok

  @impl true
  def clear, do: :ok
end

defmodule ConsumerTest.SharedID do
  @moduledoc "`await/3` проекции с общим ID заказа: поток выбирает агрегат."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order
  alias ConsumerTest.SharedID.Projection
  alias ConsumerTest.Shipment

  # G4g — общий ID: оба владельца потока ждутся по своему агрегату
  def g4g_order(%Order.ID{} = id), do: Projection.await(Order, id, 100)
  def g4g_shipment(%Order.ID{} = id), do: Projection.await(Shipment, id, 100)

  # G4ga — общий ID: агрегат не из `events:`
  def g4ga_foreign_aggregate(%Order.ID{} = id),
    # expect: incompatible types given to ConsumerTest.SharedID.Projection.await/3
    do: Projection.await(Account, id, 100)
end
