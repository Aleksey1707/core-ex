defmodule Consumer.Domain.Sales.Account do
  @moduledoc """
  Корректный агрегат: команды в стиле `%command{} when command in @on_existing`, два события одной
  командой через `fold/3`, события с нагрузкой и без, `evolve/2` с паттерном `%Payload{}` и без.
  """

  alias Consumer.Domain.Sales.Account.Cmd
  alias Consumer.Domain.Sales.Account.Errors
  alias Consumer.Domain.Sales.Account.Event
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Account.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Счёт",
      version: 7

    use Core.Labels.ID,
      kind: :ref,
      entity: :account,
      resolver: Consumer.Domain.Sales.Account.Query
  end

  defmodule Name do
    use Core.Prim.String,
      name: "Название счёта",
      min_len: 1,
      max_len: 50
  end

  defmodule Currency do
    use Core.Prim.String,
      name: "Валюта счёта",
      min_len: 3,
      max_len: 3

    use Core.Labels.Text, with: &Consumer.Domain.Sales.Account.Currency.title/1

    def title(%__MODULE__{value: "RUB"}), do: "Рубль"
    def title(%__MODULE__{} = currency), do: value(currency)
  end

  defmodule Holder do
    use Core.Prim.String,
      name: "Владелец счёта",
      min_len: 1,
      max_len: 100,
      personal: true
  end

  defmodule Status do
    use Core.Enum,
      name: "Статус счёта",
      values: ~w(open frozen closed)a
  end

  use Core.Struct,
    fields: [
      id: [prim: ID],
      version: [prim: Version, optional: true],
      name: [prim: Name, optional: true],
      status: [enum: Status, optional: true],
      holder: [prim: Holder, optional: true]
    ]

  @on_existing [Cmd.Rename, Cmd.SetHolder, Cmd.Freeze, Cmd.Close]

  @impl true
  def decide(%Cmd.Open{name: name}, %__MODULE__{version: nil}),
    do: {:ok, [Event.Opened.draft(Event.Opened.Payload.new(name))]}

  def decide(%Cmd.Open{}, %__MODULE__{} = state),
    do: {:error, Errors.domain(__MODULE__, :already_exists, %{version: Version.value(state.version)})}

  def decide(%command{}, %__MODULE__{version: nil}) when command in @on_existing,
    do: {:error, Errors.domain(__MODULE__, :not_found, nil)}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{name: name}), do: {:ok, []}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
    do: {:ok, [Event.Renamed.draft(Event.Renamed.Payload.new(name))]}

  def decide(%Cmd.SetHolder{holder: holder}, %__MODULE__{status: :open}),
    do: {:ok, [Event.HolderSet.draft(Event.HolderSet.Payload.new(holder))]}

  def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen.draft()]}
  def decide(%Cmd.Close{}, %__MODULE__{status: :frozen}), do: {:ok, [Event.Closed.draft()]}

  def decide(%Cmd.Close{} = command, %__MODULE__{status: :open} = state) do
    freeze = %Cmd.Freeze{at: command.at, by: command.by}

    with {:ok, frozen} <- decide(freeze, state),
         {:ok, closed} <- decide(command, fold(state, freeze, frozen)) do
      {:ok, frozen ++ closed}
    end
  end

  def decide(%command{}, %__MODULE__{} = state) when command in @on_existing,
    do: {:error, Errors.domain(__MODULE__, :invalid_status, %{status: state.status})}

  @impl true
  def evolve(state, %Event.Opened{payload: %Event.Opened.Payload{} = payload}),
    do: %{state | name: payload.name, status: :open}

  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}

  def evolve(state, %Event.HolderSet{payload: %Event.HolderSet.Payload{} = payload}),
    do: %{state | holder: payload.holder}

  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}
end
