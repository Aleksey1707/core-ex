defmodule Core.Codec.PluginTest do
  use ExUnit.Case, async: true

  defmodule DumpOnlyPlugin do
    defmodule A do
      defstruct [:x]
    end

    defmodule B do
      defstruct [:y]
    end

    use Core.Codec.Plugin,
      types: [A, B],
      loadable: false

    @impl true
    def dump(%A{}, _codec), do: :a
    def dump(%B{}, _codec), do: :b
  end

  defmodule UnionPlugin do
    defmodule Family do
    end

    defmodule X do
      defstruct []
    end

    use Core.Codec.Plugin,
      types: [X],
      union: Family

    @impl true
    def dump(%X{}, _codec), do: %{}

    @impl true
    def load(Family, _raw, _codec), do: {:ok, %X{}}
    def load(X, _raw, _codec), do: {:ok, %X{}}
  end

  test "types объявляют обслуживаемые модули" do
    assert Enum.sort(DumpOnlyPlugin.__codec_types__()) ==
             Enum.sort([DumpOnlyPlugin.A, DumpOnlyPlugin.B])

    refute DumpOnlyPlugin.__codec_loadable__()
    assert DumpOnlyPlugin.__codec_union__() == nil
  end

  test "union объявляет модуль-семейство" do
    assert UnionPlugin.__codec_union__() == UnionPlugin.Family
    assert UnionPlugin.__codec_types__() == [UnionPlugin.X]
    assert {:ok, %UnionPlugin.X{}} = UnionPlugin.load(UnionPlugin.Family, %{}, __MODULE__)
  end

  test "loadable true without load/3 raises CompileError" do
    assert_raise CompileError, ~r/must define load\/3/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NoLoad do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin, types: [X]

            @impl true
            def dump(%X{}, _codec), do: :ok
          end
        end
      )
    end
  end

  test "union с loadable: false — CompileError" do
    assert_raise CompileError, ~r/union: requires loadable: true/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.DumpOnlyUnion do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin,
              types: [X],
              union: Core.Codec.PluginTest.DumpOnlyUnion,
              loadable: false

            @impl true
            def dump(%X{}, _codec), do: :ok
          end
        end
      )
    end
  end

  test "union не модуль — CompileError" do
    assert_raise CompileError, ~r/union: must be a module/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.BadUnion do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin,
              types: [X],
              union: "family"

            @impl true
            def dump(%X{}, _codec), do: :ok

            @impl true
            def load(X, _raw, _codec), do: {:ok, %X{}}
          end
        end
      )
    end
  end

  test "types обязательны и непусты" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:types\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NoTypes do
            use Core.Codec.Plugin, loadable: false
          end
        end
      )
    end

    assert_raise CompileError, ~r/types: must be a non-empty list/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.EmptyTypes do
            use Core.Codec.Plugin,
              types: [],
              loadable: false
          end
        end
      )
    end
  end
end
