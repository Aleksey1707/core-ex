defmodule Core.Codec.PluginTest do
  use ExUnit.Case, async: true

  defmodule TagsMapPlugin do
    defmodule A do
      defstruct [:x]
    end

    defmodule B do
      defstruct [:y]
    end

    use Core.Codec.Plugin,
      tags: %{A => "a", B => "b"},
      loadable: false

    @impl true
    def dump(%A{}, _codec), do: :a
    def dump(%B{}, _codec), do: :b
  end

  defmodule TaggedPlugin do
    defmodule X do
      defstruct []
    end

    use Core.Codec.Plugin,
      tags: %{X => "x"},
      tagged: true,
      loadable: false

    @impl true
    def dump(%X{}, _codec), do: {"x", %{}}

    @impl true
    def load_tagged("x", _payload, _codec), do: {:ok, %X{}}
    def load_tagged(_type, _payload, _codec), do: {:error, :unknown}
  end

  test "tags map generates type/1, types/0, mod_by_tag/1" do
    assert TagsMapPlugin.type(TagsMapPlugin.A) == "a"
    assert TagsMapPlugin.type(%TagsMapPlugin.A{x: 1}) == "a"
    assert MapSet.equal?(TagsMapPlugin.types(), MapSet.new(["a", "b"]))
    assert {:ok, TagsMapPlugin.A} = TagsMapPlugin.mod_by_tag("a")
    assert :error = TagsMapPlugin.mod_by_tag("nope")

    assert Enum.sort(TagsMapPlugin.__codec_types__()) ==
             Enum.sort([TagsMapPlugin.A, TagsMapPlugin.B])

    assert Enum.sort(TagsMapPlugin.__codec_tags__()) == ["a", "b"]
  end

  test "tagged plugin with tags map" do
    assert TaggedPlugin.__codec_tagged__()
    assert TaggedPlugin.type(TaggedPlugin.X) == "x"
    assert {:ok, %TaggedPlugin.X{}} = TaggedPlugin.load_tagged("x", %{}, __MODULE__)
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

  test "tagged true without load_tagged/3 raises CompileError" do
    assert_raise CompileError, ~r/must define load_tagged\/3/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NoLoadTagged do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin,
              tags: %{X => "x"},
              tagged: true,
              loadable: false

            @impl true
            def dump(%X{}, _codec), do: :ok
          end
        end
      )
    end
  end

  test "tagged true without tags map raises CompileError" do
    assert_raise CompileError, ~r/tagged: true requires tags:/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.TaggedNoMap do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin,
              types: [X],
              tagged: true,
              loadable: false

            @impl true
            def dump(%X{}, _codec), do: :ok
          end
        end
      )
    end
  end

  test "types and tags are mutually exclusive" do
    assert_raise CompileError, ~r/mutually exclusive/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.XorFail do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin,
              types: [X],
              tags: %{X => "x"},
              loadable: false

            @impl true
            def dump(%X{}, _codec), do: :ok
          end
        end
      )
    end
  end
end
