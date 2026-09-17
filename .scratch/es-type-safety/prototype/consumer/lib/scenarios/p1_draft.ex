defmodule Blind.BadDraft do
  alias Blind.Account.Cmd
  alias Blind.Account.Event
  alias Blind.Order

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  # B1 — событие не из кодека: модуль события без нагрузки чужого агрегата
  @impl true
  def decide(%Cmd.Freeze{}, %__MODULE__{}),
    # expect: incompatible types given to Blind.Account.Event.Codec.draft/1
    do: {:ok, [Event.Codec.draft(Order.Event.Cancelled)]}

  # B1p — нагрузка события чужого агрегата, литерал
  def decide(%Cmd.Open{}, %__MODULE__{}),
    # expect: incompatible types given to Blind.Account.Event.Codec.draft/1
    do: {:ok, [Event.Codec.draft(%Order.Event.Placed.Payload{amount: nil})]}

  # B1n — нагрузка события чужого агрегата из Payload.new/1 того же проекта
  def decide(%Cmd.Rename{}, %__MODULE__{}),
    # expect: incompatible types given to Blind.Account.Event.Codec.draft/1
    do: {:ok, [Event.Codec.draft(Order.Event.Placed.Payload.new(Order.Amount.new!(1)))]}

  # B3 — голый модуль события, которому нужна нагрузка
  def decide(%Cmd.Close{}, %__MODULE__{}),
    # expect: incompatible types given to Blind.Account.Event.Codec.draft/1
    do: {:ok, [Event.Codec.draft(Event.Opened)]}

  # B2t — обход конструктора: кортеж с нагрузкой чужого события своего кодека
  def decide(%Cmd.Orphan{}, %__MODULE__{}),
    do: {:ok, [{Event.Opened, %Event.Renamed.Payload{name: nil}}]}

  @impl true
  def evolve(state, %Event.Opened{}), do: state
  def evolve(state, %Event.Renamed{}), do: state
  def evolve(state, %Event.Frozen{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule Blind.S.Draft do
  alias Blind.Account.Event

  # B1d — прямой вызов конструктора с нагрузкой неизвестного типа (параметр)
  def b1d_dynamic_payload(payload), do: Event.Codec.draft(payload)

  # B1s — строка вместо нагрузки
  # expect: incompatible types given to Blind.Account.Event.Codec.draft/1
  def b1s_string, do: Event.Codec.draft("opened")
end
