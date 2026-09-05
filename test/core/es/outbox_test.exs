defmodule Core.Es.OutboxTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.EventFixture
  alias Core.Outbox

  defmodule Fixture do
    @moduledoc false

    use Core.Es.Outbox,
      topic: "fakes",
      event: Core.EventFixture.Event
  end

  defmodule FakeEvent do
    @moduledoc false

    defstruct ~w(id aggregate_id aggregate_version at by)a

    @type t :: %__MODULE__{}
  end

  test "генерирует from_event/1 и from_events/1" do
    {impl, _} =
      Code.eval_quoted(
        quote do
          defmodule Core.Es.OutboxTest.Ok do
            use Core.Es.Outbox,
              topic: "fakes",
              event: Core.Es.OutboxTest.FakeEvent
          end

          Core.Es.OutboxTest.Ok
        end
      )

    assert function_exported?(impl, :from_event, 1)
    assert function_exported?(impl, :from_events, 1)
  end

  test "требует обязательные опции" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:event\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.OutboxTest.MissingEvent do
            use Core.Es.Outbox, topic: "fakes"
          end
        end
      )
    end
  end

  test "отклоняет неизвестную опцию" do
    assert_raise CompileError, ~r/unknown option\(s\): \[:weird\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.OutboxTest.UnknownOpt do
            use Core.Es.Outbox,
              topic: "fakes",
              event: Core.Es.OutboxTest.FakeEvent,
              weird: true
          end
        end
      )
    end
  end

  test "отклоняет невалидный topic на этапе компиляции" do
    assert_raise CompileError, ~r/topic:/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.OutboxTest.BadTopic do
            use Core.Es.Outbox,
              topic: "не топик",
              event: Core.Es.OutboxTest.FakeEvent
          end
        end
      )
    end
  end

  describe "запись из события" do
    test "payload — конверт события целиком" do
      event = EventFixture.created()

      assert {:ok, record} = Fixture.from_event(event)
      assert record.payload == InCodec.dump(event)
    end

    test "ключ, имя и заголовки берутся из того же конверта" do
      event = EventFixture.created()
      data = InCodec.dump(event)

      assert {:ok, record} = Fixture.from_event(event)

      assert Outbox.Key.value(record.key) == data["aggregate_id"]
      assert Outbox.Name.value(record.name) == data["type"]

      assert record.headers == %{
               "name" => data["type"],
               "aggr_id" => data["aggregate_id"],
               "event_id" => data["event_id"]
             }
    end
  end
end
