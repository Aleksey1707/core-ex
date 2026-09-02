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

  defmodule SampleView do
    defstruct [:id, :created_at, :closed_at]
  end

  defmodule SampleViewCodec do
    use Core.Codec.Plugin,
      types: [SampleView],
      loadable: false

    @impl true
    def dump(%SampleView{} = view, codec) do
      %{
        id: codec.dump_raw(:uuid, view.id),
        created_at: codec.dump_raw(:datetime, view.created_at),
        closed_at: dump_raw_optional(view.closed_at, :datetime, codec)
      }
    end
  end

  defmodule ViewFacade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.External,
      plugins: [SampleViewCodec]
  end

  test "load_tagged exists without tagged plugins" do
    assert function_exported?(EmptyFacade, :load_tagged, 2)

    assert {:error, %Error{code: :unknown_tagged_type, module: EmptyFacade}} =
             EmptyFacade.load_tagged("any", %{})
  end

  test "load_tagged rejects non-binary type and non-map payload" do
    assert {:error, %Error{code: :invalid_tagged_input, module: InCodec}} =
             InCodec.load_tagged(nil, %{})

    assert {:error, %Error{code: :invalid_tagged_input, module: InCodec}} =
             InCodec.load_tagged(123, %{})

    assert {:error, %Error{code: :invalid_tagged_input, module: InCodec}} =
             InCodec.load_tagged("create", "not-a-map")
  end

  test "unknown tagged type uses facade as error module" do
    assert {:error, %Error{code: :unknown_tagged_type, module: InCodec}} =
             InCodec.load_tagged("nope", %{})
  end

  test "dump unknown non-prim struct raises ArgumentError" do
    assert_raise ArgumentError, ~r/нет codec-плагина/, fn ->
      InCodec.dump(%UnknownStruct{x: 1})
    end
  end

  test "dump prim still works via fallback" do
    assert is_integer(InCodec.dump(Version.new!(1)))
    assert is_binary(InCodec.dump(SampleString.new!("ab")))
  end

  test "dump_raw delegates to the prim profile of the facade" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    dt = DateTime.utc_now()

    assert ViewFacade.dump_raw(:uuid, uuid) ==
             Core.CodecFixture.Prim.External.dump_raw(:uuid, uuid)

    assert InCodec.dump_raw(:uuid, uuid) == Core.CodecFixture.Prim.Internal.dump_raw(:uuid, uuid)
    assert ViewFacade.dump_raw(:datetime, dt) == local_iso(dt)
  end

  test "dump-only view plugin formats raw values like the prim path" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    dt = DateTime.utc_now()

    assert %{id: id, created_at: created_at, closed_at: nil} =
             ViewFacade.dump(%SampleView{id: uuid, created_at: dt})

    assert id == ViewFacade.dump(SampleUUID.new!(uuid))
    assert created_at == local_iso(dt)

    assert %{closed_at: closed_at} =
             ViewFacade.dump(%SampleView{id: uuid, created_at: dt, closed_at: dt})

    assert closed_at == local_iso(dt)
  end

  test "view struct is dump-only: load raises" do
    assert_raise ArgumentError, ~r/dump-only плагин/, fn ->
      ViewFacade.load(SampleView, %{})
    end
  end

  test "dump and load compose via prim profile" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    composed = ApproverID.new!(uuid)

    dumped = InCodec.dump(composed)
    assert dumped == InCodec.dump(SampleUUID.new!(uuid))
    assert {:ok, ^composed} = InCodec.load(ApproverID, dumped)
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

  test "duplicate codec types raise CompileError" do
    assert_raise CompileError, ~r/duplicate codec type/, fn ->
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

  test "non-plugin in plugins list raises CompileError" do
    assert_raise CompileError, ~r/must implement Codec.Plugin/, fn ->
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
