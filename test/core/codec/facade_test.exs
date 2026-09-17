defmodule Core.Codec.FacadeTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Error
  alias Core.Prim
  alias Core.Version

  defmodule EmptyFacade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: []
  end

  defmodule SampleString do
    use Prim.String, name: "Имя", min_len: 1, max_len: 50
  end

  defmodule SampleUUID do
    use Prim.UUID, name: "ID", version: 4
  end

  defmodule ApproverID do
    use Prim.Compose, name: "Согласующий", of: SampleUUID
  end

  defmodule UnknownStruct do
    defstruct [:x]
  end

  defmodule ValueStruct do
    defstruct [:value]
  end

  defmodule SampleAt do
    use Prim.DateTime, name: "Момент"
  end

  defmodule SampleView do
    defstruct [:id, :created_at, :closed_at]
  end

  defmodule SampleViewCodec do
    use Core.Codec.Plugin,
      types: [SampleView],
      loadable: false

    alias Core.Codec.FacadeTest.SampleAt
    alias Core.Codec.FacadeTest.SampleUUID

    @impl true
    def dump(%SampleView{} = view, codec) do
      %{
        id: dump_raw(SampleUUID, view.id, codec),
        created_at: dump_raw(SampleAt, view.created_at, codec),
        closed_at: dump_raw(SampleAt, view.closed_at, codec)
      }
    end
  end

  defmodule ViewFacade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.External,
      plugins: [SampleViewCodec]
  end

  test "фасад отдаёт только dump/1, load/2 и load!/2" do
    exported =
      EmptyFacade.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> match?("__" <> _, Atom.to_string(name)) end)
      |> Enum.sort()

    assert exported == [dump: 1, load: 2, load!: 2]
  end

  test "dump struct без плагина и без поля value — FunctionClauseError" do
    assert_raise FunctionClauseError, fn ->
      InCodec.dump(struct(UnknownStruct, x: 1))
    end
  end

  test "dump struct с полем value, который не Prim, — ArgumentError" do
    assert_raise ArgumentError, ~r/нет codec-плагина/, fn ->
      InCodec.dump(%ValueStruct{value: 1})
    end
  end

  test "dump prim still works via fallback" do
    assert is_integer(InCodec.dump(Version.new!(1)))
    assert is_binary(InCodec.dump(SampleString.new!("ab")))
  end

  test "dump-only view plugin formats raw values like the prim path" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    dt = DateTime.utc_now()

    assert %{id: id, created_at: created_at, closed_at: nil} =
             ViewFacade.dump(%SampleView{id: uuid, created_at: dt})

    assert id == ViewFacade.dump(SampleUUID.new!(uuid))
    assert created_at == ViewFacade.dump(SampleAt.new!(dt))

    assert %{closed_at: closed_at} =
             ViewFacade.dump(%SampleView{id: uuid, created_at: dt, closed_at: dt})

    assert closed_at == ViewFacade.dump(SampleAt.new!(dt))
  end

  test "raw-путь наследует precision своего Prim, а не форму значения" do
    dt = DateTime.utc_now()

    assert %{created_at: created_at} = ViewFacade.dump(%SampleView{id: nil, created_at: dt})

    refute created_at =~ "."
    assert created_at == local_iso(DateTime.truncate(dt, :second))
  end

  test "view struct is dump-only: load raises" do
    assert_raise ArgumentError, ~r/dump-only плагин/, fn ->
      ViewFacade.load(SampleView, %{})
    end

    assert_raise ArgumentError, ~r/dump-only плагин/, fn ->
      ViewFacade.load!(SampleView, %{})
    end
  end

  test "dump and load compose via prim profile" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    composed = ApproverID.new!(uuid)

    dumped = InCodec.dump(composed)
    assert dumped == InCodec.dump(SampleUUID.new!(uuid))
    assert {:ok, ^composed} = InCodec.load(ApproverID, dumped)
    assert ^composed = InCodec.load!(ApproverID, dumped)
  end

  test "load! prim: ошибка — Core.Exc" do
    assert_raise Core.Exc, fn -> InCodec.load!(SampleString, "") end
  end

  test "dump prim works when module is not loaded yet" do
    mod = Core.PrimFixture.PurgeableDump
    id = mod.new()

    :code.purge(mod)
    true = :code.delete(mod)
    :code.purge(mod)
    refute :erlang.module_loaded(mod)

    assert is_binary(InCodec.dump(id))
  end

  describe "load/2 и load!/2 по модулю события" do
    test "восстанавливает событие с нагрузкой и без" do
      created = Core.EventFixture.created()
      closed = Core.EventFixture.closed()

      assert {:ok, ^created} = InCodec.load(Core.EventFixture.Event.Created, InCodec.dump(created))
      assert ^created = InCodec.load!(Core.EventFixture.Event.Created, InCodec.dump(created))
      assert {:ok, ^closed} = InCodec.load(Core.EventFixture.Event.Closed, InCodec.dump(closed))
    end

    test "ошибка загрузки — {:error, _} у load/2 и Core.Exc у load!/2" do
      assert {:error, %Error{code: :invalid_envelope, ns: :es}} =
               InCodec.load(Core.EventFixture.Event.Closed, %{})

      assert_raise Core.Exc, fn -> InCodec.load!(Core.EventFixture.Event.Closed, %{}) end
    end
  end

  describe "load/2 по модулю-семейству" do
    test "восстанавливает событие по тегу внутри данных" do
      event = Core.EventFixture.created()
      data = InCodec.dump(event)

      assert {:ok, ^event} = InCodec.load(Core.EventFixture.Event, data)
      assert ^event = InCodec.load!(Core.EventFixture.Event, data)
    end

    test "неизвестный тег — доменная ошибка кодека агрегата" do
      assert {:error,
              %Error{
                code: :unknown_event_type,
                ns: :es,
                module: Core.EventFixture.Event.Codec,
                detail: "nope"
              }} = InCodec.load(Core.EventFixture.Event, %{"type" => "nope"})

      assert_raise Core.Exc, ~r/Неизвестный тип события/, fn ->
        InCodec.load!(Core.EventFixture.Event, %{"type" => "nope"})
      end
    end

    test "данные без тега — доменная ошибка кодека агрегата" do
      assert {:error, %Error{code: :invalid_envelope, ns: :es, detail: %{field: :type}}} =
               InCodec.load(Core.EventFixture.Event, %{})
    end
  end

  test "семейство в двух плагинах — CompileError" do
    assert_raise CompileError, ~r/объявлен дважды/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.DupUnionA do
            use Core.Codec.Plugin,
              types: [Core.Codec.FacadeTest.UnknownStruct],
              union: Core.EventFixture.Event

            @impl true
            def dump(%Core.Codec.FacadeTest.UnknownStruct{}, _codec), do: %{}

            @impl true
            def load(_mod, _raw, _codec), do: {:ok, nil}
          end

          defmodule Core.Codec.FacadeTest.DupUnionFacade do
            use Core.Codec.Facade,
              prim: Core.CodecFixture.Prim.Internal,
              plugins: [Core.EventFixture.Event.Codec, Core.Codec.FacadeTest.DupUnionA]
          end
        end
      )
    end
  end

  test "тип агрегата в двух кодеках событий — CompileError с именами обоих" do
    assert_raise CompileError, ~r/тип агрегата "fixture".*DupTypeCodec.*EventFixture/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.DupTypeEvent do
            defmodule Opened do
              use Core.Es.Event,
                aggregate_id: Core.EventFixture.AggID,
                by: Core.EventFixture.ActorID,
                payload: nil
            end
          end

          defmodule Core.Codec.FacadeTest.DupTypeCodec do
            use Core.Es.Event.Codec,
              event: Core.Codec.FacadeTest.DupTypeEvent,
              type: "fixture",
              tags: %{Core.Codec.FacadeTest.DupTypeEvent.Opened => "fixture.opened"}
          end

          defmodule Core.Codec.FacadeTest.DupTypeFacade do
            use Core.Codec.Facade,
              prim: Core.CodecFixture.Prim.Internal,
              plugins: [Core.EventFixture.Event.Codec, Core.Codec.FacadeTest.DupTypeCodec]
          end
        end
      )
    end
  end

  test "duplicate codec types raise CompileError" do
    assert_raise CompileError, ~r/объявлен дважды/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.DupA do
            use Core.Codec.Plugin,
              types: [Core.Version],
              loadable: false

            @impl true
            def dump(%Core.Version{} = v, _codec), do: v
          end

          defmodule Core.Codec.FacadeTest.DupB do
            use Core.Codec.Plugin,
              types: [Core.Version],
              loadable: false

            @impl true
            def dump(%Core.Version{} = v, _codec), do: v
          end

          defmodule Core.Codec.FacadeTest.DupFacade do
            use Core.Codec.Facade,
              prim: Core.CodecFixture.Prim.Internal,
              plugins: [
                Core.Codec.FacadeTest.DupA,
                Core.Codec.FacadeTest.DupB
              ]
          end
        end
      )
    end
  end

  test "prim: не модуль — CompileError" do
    assert_raise CompileError, ~r/ожидается модуль/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.BadPrimFacade do
            use Core.Codec.Facade, prim: "профиль"
          end
        end
      )
    end
  end

  test "prim: модуль без интерфейса профиля — CompileError" do
    assert_raise CompileError, ~r/должен экспортировать dump\/1/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.NotProfileFacade do
            use Core.Codec.Facade, prim: String
          end
        end
      )
    end
  end

  test "не-модуль в plugins — CompileError" do
    assert_raise CompileError, ~r/плагин .*ожидается модуль/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.NotModulePluginFacade do
            use Core.Codec.Facade,
              prim: Core.CodecFixture.Prim.Internal,
              plugins: ["строка"]
          end
        end
      )
    end
  end

  test "non-plugin in plugins list raises CompileError" do
    assert_raise CompileError, ~r/должен реализовывать Codec.Plugin/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.FacadeTest.BadPluginFacade do
            use Core.Codec.Facade,
              prim: Core.CodecFixture.Prim.Internal,
              plugins: [String]
          end
        end
      )
    end
  end

  # ---

  defp local_iso(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!(Core.Config.tz())
    |> DateTime.to_iso8601()
  end
end
