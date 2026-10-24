defmodule Core.Es.EventTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.Version

  defmodule ValuePayload do
    @moduledoc false
    defstruct [:value]
    @type t :: %__MODULE__{value: term()}
    def new(value), do: %__MODULE__{value: value}
  end

  defmodule EventWithPayload do
    @moduledoc false
    use Event,
      family: Core.EventFixture.Event,
      payload: ValuePayload
  end

  defmodule EmptyEvent do
    @moduledoc false
    use Event, family: Core.EventFixture.Event, payload: nil
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

  test "draft/1 — черновик события с нагрузкой: модуль события и нагрузка" do
    payload = ValuePayload.new(:ok)

    assert EventWithPayload.draft(payload) == {EventWithPayload, payload}
  end

  test "draft/0 — черновик события без нагрузки: модуль события" do
    assert EmptyEvent.draft() == EmptyEvent
  end

  test "Prim агрегата и автора — у семейства family:" do
    assert EmptyEvent.__es_family__() == Core.EventFixture.Event
    assert EmptyEvent.__es_aggregate_id__() == AggID
    assert EmptyEvent.__es_by__() == ActorID
  end

  describe "declared?/1" do
    test "событие, которое ещё собирается, — да; модуль без use — нет" do
      defmodule DeclaredEvent do
        @moduledoc false
        use Core.Es.Event, family: Core.EventFixture.Event, payload: nil

        @declared Core.Es.Event.declared?(__MODULE__)

        def declared, do: @declared
      end

      defmodule UndeclaredEvent do
        @moduledoc false

        @declared Core.Es.Event.declared?(__MODULE__)

        def declared, do: @declared
      end

      assert DeclaredEvent.declared()
      refute UndeclaredEvent.declared()
    end
  end

  describe "отказ сборки use" do
    test "неизвестная опция" do
      assert_raise CompileError, ~r/Es.Event: неизвестные опции: \[:codec\]$/, fn ->
        compile_event(:UnknownOpt, family: Core.EventFixture.Event, payload: nil, codec: AggID)
      end
    end

    test "нет обязательной опции" do
      assert_raise CompileError, ~r/Es.Event: нет обязательных опций: \[:payload\]$/, fn ->
        compile_event(:NoPayloadOpt, family: Core.EventFixture.Event)
      end
    end

    test "старая форма aggregate_id: / by: — недостающая и неизвестные опции одним сообщением" do
      message = ~r/Es.Event: нет обязательных опций: \[:family\]; неизвестные опции: \[:aggregate_id, :by\]$/

      assert_raise CompileError, message, fn ->
        compile_event(:OldForm, aggregate_id: AggID, by: ActorID, payload: nil)
      end
    end

    test "family: — не семейство" do
      message = ~r/Es.Event: family: модуль Core\.EventFixture\.AggID должен экспортировать __es_aggregate_id__\/0/

      assert_raise CompileError, message, fn ->
        compile_event(:NotFamily, family: AggID, payload: nil)
      end
    end

    test ":payload — не модуль и не nil" do
      assert_raise CompileError, ~r/Es.Event: :payload должен быть модулем или nil/, fn ->
        compile_event(:StringPayload, family: Core.EventFixture.Event, payload: "ValuePayload")
      end
    end

    test "payload: вложен ниже use — модуль недоступен, а не тихий пропуск проверок" do
      assert_raise CompileError, ~r/Es.Event: payload: .*LatePayload\.Payload недоступен/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.EventTest.LatePayload do
              use Core.Es.Event, family: Core.EventFixture.Event, payload: __MODULE__.Payload

              defmodule Payload do
                defstruct [:value]
              end
            end
          end
        )
      end
    end
  end

  # ---

  defp compile_event(name, opts) do
    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.Event, unquote(opts)
        end
      end
    )
  end
end
