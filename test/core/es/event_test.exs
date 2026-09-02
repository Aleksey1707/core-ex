defmodule Core.Es.EventTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event
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

  defmodule EventWithPayload do
    @moduledoc false
    use Event,
      aggregate_id: AggID,
      by: ActorID,
      payload: ValuePayload
  end

  defmodule EmptyEvent do
    @moduledoc false
    use Event, aggregate_id: AggID, by: ActorID, payload: nil
  end

  test "new создаёт событие с нагрузкой" do
    version = Version.new()
    agg_id = AggID.new()
    by = ActorID.new()
    at = Event.At.now!()
    payload = ValuePayload.new(:ok)

    event = EventWithPayload.new(payload, agg_id, version, by, at)

    assert %EventWithPayload{
             id: %Event.ID{},
             payload: ^payload,
             aggregate_id: ^agg_id,
             aggregate_version: ^version,
             at: ^at,
             by: ^by
           } = event
  end

  test "new создаёт событие без нагрузки" do
    event =
      EmptyEvent.new(
        AggID.new(),
        Version.new(),
        ActorID.new(),
        Event.At.now!()
      )

    assert %EmptyEvent{id: %Event.ID{}, payload: nil} = event
  end

  test "new восстанавливает событие с заданным id" do
    id = Event.ID.new()
    payload = ValuePayload.new(:ok)

    event =
      EventWithPayload.new(
        payload,
        AggID.new(),
        Version.new(),
        ActorID.new(),
        Event.At.now!(),
        id
      )

    assert %EventWithPayload{id: ^id, payload: ^payload} = event
  end
end
