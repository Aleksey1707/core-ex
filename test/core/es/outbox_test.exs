defmodule Core.Es.OutboxTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.EventFixture
  alias Core.Otel
  alias Core.Outbox

  defmodule Fixture do
    @moduledoc false

    use Core.Es.Outbox,
      topic: "fakes",
      family: Core.EventFixture.Event
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
              family: Core.Es.OutboxTest.FakeEvent
          end

          Core.Es.OutboxTest.Ok
        end
      )

    assert Core.Helper.Module.exports?(impl, :from_event, 1)
    assert Core.Helper.Module.exports?(impl, :from_events, 1)
  end

  test "topic/0 отдаёт топик из опции topic: строкой" do
    assert Fixture.topic() == "fakes"
  end

  test "требует обязательные опции" do
    assert_raise CompileError, ~r/нет обязательных опций: \[:family\]/, fn ->
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
    assert_raise CompileError, ~r/неизвестные опции: \[:weird\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.OutboxTest.UnknownOpt do
            use Core.Es.Outbox,
              topic: "fakes",
              family: Core.Es.OutboxTest.FakeEvent,
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
              family: Core.Es.OutboxTest.FakeEvent
          end
        end
      )
    end
  end

  describe "опции use" do
    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Outbox: неизвестные опции: \[:topik\]$/, fn ->
        expand_using(topic: "fakes", family: Core.EventFixture.Event, topik: "fakes")
      end
    end

    test "атрибут в topic: — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Es\.Outbox: topic: ожидается литерал, получено @topic$/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Core.Es.OutboxTest.AttrTopic do
              @topic "fakes"

              use Core.Es.Outbox,
                topic: @topic,
                family: Core.EventFixture.Event
            end
          end
        )
      end
    end
  end

  describe "запись из события" do
    test "время записи реальное при остановленных часах" do
      :ok = Core.Clock.Test.freeze(~U[2000-01-01 00:00:00Z])

      assert {:ok, record} = Fixture.from_event(EventFixture.created())
      assert_in_delta DateTime.to_unix(Outbox.CreatedAt.value(record.created_at)), System.os_time(:second), 5
    end

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

    test "traceparent команды попадает в заголовки записи" do
      event = EventFixture.created()

      assert {:ok, record} = Otel.span("cmd", [], fn -> Fixture.from_event(event) end)
      assert %{"traceparent" => traceparent} = record.headers
      assert traceparent =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$/
    end
  end

  # ---

  defp expand_using(opts) do
    {:ok, env} = Macro.Env.define_require(__ENV__, [], Core.Es.Outbox)
    Macro.expand(quote(do: Core.Es.Outbox.__using__(unquote(opts))), env)
  end
end
