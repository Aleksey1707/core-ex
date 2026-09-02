defmodule Core.Es.OutboxTest do
  use ExUnit.Case, async: true

  defmodule FakeEvent do
    @moduledoc false

    defstruct ~w(id aggregate_id aggregate_version at by)a

    @type t :: %__MODULE__{}

    def name(%__MODULE__{}), do: "faked"
  end

  defmodule NoName do
    @moduledoc false

    defstruct []

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

  test "требует у event функцию name/1" do
    assert_raise CompileError, ~r/должен экспортировать name\/1/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.OutboxTest.BadEvent do
            use Core.Es.Outbox,
              topic: "fakes",
              event: Core.Es.OutboxTest.NoName
          end
        end
      )
    end
  end
end
