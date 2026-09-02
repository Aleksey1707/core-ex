defmodule Core.Es.EventsTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Es.Event
  alias Core.Es.Events
  alias Core.Exc
  alias Core.Version

  defmodule AggID do
    @moduledoc false
    use Core.Prim.UUID, name: "agg id", version: 7
  end

  defmodule ActorID do
    @moduledoc false
    use Core.Prim.UUID, name: "actor id", version: 7
  end

  defmodule ValuePayload do
    @moduledoc false
    defstruct [:value]
    @type t :: %__MODULE__{value: term()}
    def new(value), do: %__MODULE__{value: value}
  end

  defmodule EventA do
    @moduledoc false
    use Event, aggregate_id: AggID, by: ActorID, payload: ValuePayload
  end

  defmodule EventB do
    @moduledoc false
    use Event, aggregate_id: AggID, by: ActorID, payload: nil
  end

  setup do
    agg_id = AggID.new()
    by = ActorID.new()
    at = Event.At.now!()
    version = Version.new()

    a1 = EventA.new(ValuePayload.new(1), agg_id, version, by, at)
    a2 = EventA.new(ValuePayload.new(2), agg_id, Version.next(version), by, at)
    b1 = EventB.new(agg_id, Version.next(Version.next(version)), by, at)

    events =
      Events.new()
      |> Events.add(a1)
      |> Events.add(a2)
      |> Events.add(b1)

    %{a1: a1, a2: a2, b1: b1, events: events}
  end

  test "new / empty? / count / clear" do
    assert Events.new() == []
    assert Events.empty?(Events.new())
    refute Events.empty?(Events.add(Events.new(), build_a()))
    assert Events.count(Events.new()) == 0
    assert Events.clear([:x]) == []
  end

  test "new/1 сортирует enumerable newest-first по aggregate_version", %{
    a1: a1,
    a2: a2,
    b1: b1
  } do
    assert [^b1, ^a2, ^a1] = Events.new([a1, b1, a2])
    assert [^b1, ^a2, ^a1] = Events.new(Stream.concat([[b1], [a1, a2]]))
  end

  test "add — newest-first; to_list — chronological", %{a1: a1, a2: a2, b1: b1, events: events} do
    assert [^b1, ^a2, ^a1] = events
    assert [^a1, ^a2, ^b1] = Events.to_list(events)
  end

  test "find / get / get! по id", %{a1: a1, events: events} do
    assert Events.find(events, a1.id) == a1
    assert Events.find(events, Event.ID.new()) == nil

    assert {:ok, ^a1} = Events.get(events, a1.id)

    assert {:error,
            %Error{kind: :domain, ns: :events, code: :not_found, message: "Событие не найдено"}} =
             Events.get(events, Event.ID.new())

    assert Events.get!(events, a1.id) == a1

    assert_raise Exc, fn -> Events.get!(events, Event.ID.new()) end
  end

  test "find_by_type / filter_by_type / get_by_type", %{
    a1: a1,
    a2: a2,
    b1: b1,
    events: events
  } do
    assert Events.find_by_type(events, EventB) == b1
    assert Events.find_by_type(events, EventA) == a2
    assert Events.find_by_type(events, __MODULE__) == nil

    assert [^a2, ^a1] = Events.filter_by_type(events, EventA)
    assert [^b1] = Events.filter_by_type(events, EventB)

    assert {:ok, ^b1} = Events.get_by_type(events, EventB)

    assert {:error, %Error{ns: :events, code: :not_found, detail: __MODULE__}} =
             Events.get_by_type(events, __MODULE__)

    assert Events.get_by_type!(events, EventB) == b1
    assert_raise Exc, fn -> Events.get_by_type!(events, __MODULE__) end
  end

  test "last / first — newest и oldest", %{a1: a1, b1: b1, events: events} do
    assert Events.last(events) == b1
    assert Events.first(events) == a1
    assert Events.last([]) == nil
    assert Events.first([]) == nil

    assert {:ok, ^b1} = Events.get_last(events)
    assert {:ok, ^a1} = Events.get_first(events)
    assert {:error, %Error{ns: :events, code: :not_found}} = Events.get_last([])
    assert {:error, %Error{ns: :events, code: :not_found}} = Events.get_first([])

    assert Events.get_last!(events) == b1
    assert Events.get_first!(events) == a1
    assert_raise Exc, fn -> Events.get_last!([]) end
    assert_raise Exc, fn -> Events.get_first!([]) end
  end

  test "slice — chronological индексация, возврат newest-first", %{
    a1: a1,
    a2: a2,
    b1: b1,
    events: events
  } do
    assert Events.slice(events, 0, 2) == [a2, a1]
    assert Events.slice(events, 1, 1) == [a2]
    assert Events.slice(events, 0, 3) == [b1, a2, a1]
    assert Events.slice(events, 10, 1) == []
    assert Events.slice(events, 0, 0) == []
  end

  test "member? / any? / filter", %{a1: a1, a2: a2, events: events} do
    assert Events.member?(events, a1.id)
    refute Events.member?(events, Event.ID.new())

    assert Events.any?(events, &(&1.id == a2.id))
    refute Events.any?(events, &(&1.__struct__ == __MODULE__))

    assert [^a2, ^a1] = Events.filter(events, &(&1.__struct__ == EventA))
  end

  defp build_a do
    EventA.new(
      ValuePayload.new(:x),
      AggID.new(),
      Version.new(),
      ActorID.new(),
      Event.At.now!()
    )
  end
end
