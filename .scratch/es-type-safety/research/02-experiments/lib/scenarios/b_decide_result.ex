defmodule Blind.BadDecide do
  alias Blind.Account.Cmd
  alias Blind.Account.Event
  alias Blind.Order

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  # B1 — модуль события не из tags: кодека
  @impl true
  def decide(%Cmd.Open{}, %__MODULE__{}),
    do: {:ok, [{Order.Event.Placed, %Order.Event.Placed.Payload{amount: nil}}]}

  # B2 — нагрузка чужого модуля
  def decide(%Cmd.Rename{name: name}, %__MODULE__{}),
    do: {:ok, [{Event.Opened, %Event.Renamed.Payload{name: name}}]}

  # B3 — голый модуль события, которому нужна нагрузка
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Opened]}

  @impl true
  def evolve(state, %Event.Opened{}), do: state
  def evolve(state, %Event.Renamed{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule Blind.S.DecideResult do
  alias Blind.Account
  alias Blind.BadDecide
  alias Blind.Order

  def b1_foreign_event_mod(%BadDecide{} = state, %Account.Cmd.Open{} = cmd),
    do: BadDecide.execute(state, cmd)

  def b2_foreign_payload(%BadDecide{} = state, %Account.Cmd.Rename{} = cmd),
    do: BadDecide.execute(state, cmd)

  def b3_bare_mod_with_payload(%BadDecide{} = state, %Account.Cmd.Close{} = cmd),
    do: BadDecide.execute(state, cmd)

  # B4 — те же результаты прямым вызовом fold/3
  def b4_fold3_foreign_event_mod(%Account{} = state, %Account.Cmd.Open{} = cmd),
    do: Account.fold(state, cmd, [{Order.Event.Placed, %Order.Event.Placed.Payload{amount: nil}}])

  def b5_fold3_bare_mod(%Account{} = state, %Account.Cmd.Open{} = cmd),
    do: Account.fold(state, cmd, [Account.Event.Opened])
end
