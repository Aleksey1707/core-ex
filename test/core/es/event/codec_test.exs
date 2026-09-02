defmodule Core.Es.Event.CodecTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Error
  alias Core.Es
  alias Core.Version
  require Error

  defmodule FakeId do
    @moduledoc false

    use Core.Prim.UUID,
      name: "Идентификатор",
      version: 7
  end

  defmodule Event do
    @moduledoc false

    defmodule Created do
      @moduledoc false

      use Core.Es.Event,
        aggregate_id: Core.Es.Event.CodecTest.FakeId,
        by: Core.Es.Event.CodecTest.FakeId,
        payload: nil
    end

    @type t :: Created.t()
  end

  defmodule Errors do
    @moduledoc false

    def domain(module, :unknown_event_type = code, detail) do
      Error.domain(module,
        code: code,
        ns: :fake,
        message: "Неизвестный тип события",
        detail: detail
      )
    end
  end

  defmodule NoUnknownErrors do
    @moduledoc false

    def domain(module, :not_found = code, detail) do
      Error.domain(module, code: code, ns: :fake, message: "Не найдено", detail: detail)
    end
  end

  defmodule Codec do
    @moduledoc false

    alias Core.Es
    alias Core.Es.Event.CodecTest.Errors
    alias Core.Es.Event.CodecTest.Event
    alias Core.Es.Event.CodecTest.FakeId

    @tag_by_mod %{Event.Created => "created"}

    use Es.Event.Codec,
      tags: @tag_by_mod,
      event: Event,
      aggregate_id: FakeId,
      by: FakeId,
      errors: Errors

    defp dump_payload(%Event.Created{}, _codec), do: nil

    defp load_payload(Event.Created, nil, envelope, _codec),
      do: {:ok, event(Event.Created, envelope)}
  end

  setup do
    {:ok,
     %{
       envelope:
         {FakeId.new(), Version.new(), FakeId.new(), Es.Event.At.now!(), Es.Event.ID.new()}
     }}
  end

  test "dump/2 отдаёт {type, payload}", ctx do
    {aggregate_id, version, by, at, id} = ctx.envelope
    event = Event.Created.new(aggregate_id, version, by, at, id)

    assert {"created", nil} == Codec.dump(event, InCodec)
  end

  test "load_event/8 собирает событие из envelope", ctx do
    {aggregate_id, version, by, at, id} = ctx.envelope
    event = Event.Created.new(aggregate_id, version, by, at, id)

    assert {:ok, ^event} =
             Codec.load_event("created", nil, aggregate_id, version, by, at, id, InCodec)

    assert ^event = Codec.load_event!("created", nil, aggregate_id, version, by, at, id, InCodec)
  end

  test "неизвестный wire-type — доменная ошибка из каталога агрегата", ctx do
    {aggregate_id, version, by, at, id} = ctx.envelope

    assert {:error, %Error{code: :unknown_event_type, ns: :fake} = error} =
             Codec.load_event("nope", nil, aggregate_id, version, by, at, id, InCodec)

    assert error.detail == %{type: "nope", payload: nil}
  end

  test "требует обязательные опции" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:errors\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.Event.CodecTest.MissingErrors do
            use Core.Es.Event.Codec,
              tags: %{Core.Es.Event.CodecTest.Event.Created => "created"},
              event: Core.Es.Event.CodecTest.Event,
              aggregate_id: Core.Es.Event.CodecTest.FakeId,
              by: Core.Es.Event.CodecTest.FakeId
          end
        end
      )
    end
  end

  test "требует clause :unknown_event_type в каталоге ошибок" do
    assert_raise CompileError, ~r/отсутствует clause для :unknown_event_type/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.Event.CodecTest.BadErrors do
            use Core.Es.Event.Codec,
              tags: %{Core.Es.Event.CodecTest.Event.Created => "created"},
              event: Core.Es.Event.CodecTest.Event,
              aggregate_id: Core.Es.Event.CodecTest.FakeId,
              by: Core.Es.Event.CodecTest.FakeId,
              errors: Core.Es.Event.CodecTest.NoUnknownErrors
          end
        end
      )
    end
  end
end
