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

  test "плагин без dump/2 — CompileError" do
    assert_raise CompileError, ~r/требуется dump\/2/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NoDump do
            defmodule X do
              defstruct []
            end

            use Core.Codec.Plugin,
              types: [X],
              loadable: false
          end
        end
      )
    end
  end

  test "loadable true without load/3 raises CompileError" do
    assert_raise CompileError, ~r/требуется load\/3/, fn ->
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
    assert_raise CompileError, ~r/^Codec\.Plugin: union: требует loadable: true$/, fn ->
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
    assert_raise CompileError, ~r/^Codec\.Plugin: union: ожидается модуль, получено "family"$/, fn ->
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

  test "плагин без типов — CompileError" do
    assert_raise CompileError, ~r/нет типов — задайте types:, fields: или variants:/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NoTypes do
            use Core.Codec.Plugin, loadable: false
          end
        end
      )
    end

    assert_raise CompileError, ~r/нет типов/, fn ->
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

  test "опечатка в ключе — при раскрытии, с меткой" do
    assert_raise CompileError, ~r/^Codec\.Plugin: неизвестные опции: \[:type\]$/, fn ->
      {:ok, env} = Macro.Env.define_require(__ENV__, [], Core.Codec.Plugin)
      Macro.expand(quote(do: Core.Codec.Plugin.__using__(type: [Core.Version])), env)
    end
  end

  test "loadable: не boolean — при раскрытии, с меткой" do
    assert_raise CompileError, ~r/^Codec\.Plugin: loadable: ожидается true или false, получено :no$/, fn ->
      {:ok, env} = Macro.Env.define_require(__ENV__, [], Core.Codec.Plugin)
      Macro.expand(quote(do: Core.Codec.Plugin.__using__(types: [Core.Version], loadable: :no)), env)
    end
  end

  test "атрибут в опции-литерале — «ожидается литерал»" do
    assert_raise CompileError, ~r/^Codec\.Plugin: fields: ожидается литерал, получено @fields$/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.AttrFields do
            defmodule X do
              defstruct [:a]
            end

            @fields [{X, a: [type: :string]}]
            use Core.Codec.Plugin, fields: @fields
          end
        end
      )
    end

    assert_raise CompileError, ~r/^Codec\.Plugin: union: ожидается литерал, получено @family$/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.AttrUnion do
            @family Core.Codec.PluginTest.AttrUnion
            use Core.Codec.Plugin, types: [Core.Version], union: @family
          end
        end
      )
    end
  end

  test "types: выражение — вычисляется в теле" do
    {{:module, mod, _bin, _}, _binding} =
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.ExprTypes do
            defmodule X do
              defstruct []
            end

            @types %{Core.Codec.PluginTest.ExprTypes.X => "x"}
            use Core.Codec.Plugin, types: Map.keys(@types), loadable: false

            @impl true
            def dump(%Core.Codec.PluginTest.ExprTypes.X{}, _codec), do: :x
          end
        end
      )

    assert mod.__codec_types__() == [Core.Codec.PluginTest.ExprTypes.X]
  end

  test "types: неверное выражение — в теле, с меткой" do
    assert_raise CompileError, ~r/^Codec\.Plugin: types: ожидается список модулей, получено :x$/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.BadExprTypes do
            @types :x
            use Core.Codec.Plugin, types: @types, loadable: false
          end
        end
      )
    end
  end

  test "вложенный модуль ниже use — «недоступен»" do
    assert_raise CompileError,
                 ~r/^Codec\.Plugin .*NestedBelow: fields, тип .*NestedBelow\.X: .*NestedBelow\.X недоступен/,
                 fn ->
                   Code.eval_quoted(
                     quote do
                       defmodule Core.Codec.PluginTest.NestedBelow do
                         use Core.Codec.Plugin, fields: [{Core.Codec.PluginTest.NestedBelow.X, a: [type: :string]}]

                         defmodule X do
                           defstruct [:a]
                         end
                       end
                     end
                   )
                 end

    assert_raise CompileError,
                 ~r/^Codec\.Plugin .*NestedVariant: variants, вариант .*NestedVariant\.X: .* недоступен/,
                 fn ->
                   Code.eval_quoted(
                     quote do
                       defmodule Core.Codec.PluginTest.NestedVariant do
                         use Core.Codec.Plugin,
                           union: Core.Codec.PluginTest.NestedVariant,
                           variants: [{Core.Codec.PluginTest.NestedVariant.X, "x", a: [type: :string]}]

                         defmodule X do
                           defstruct [:a]
                         end
                       end
                     end
                   )
                 end
  end

  test "вложенный модуль выше use — fields: и variants: собираются" do
    {{:module, mod, _bin, _}, _binding} =
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NestedAbove do
            defmodule X do
              defstruct [:a]
            end

            defmodule Y do
              defstruct [:b]
            end

            use Core.Codec.Plugin,
              fields: [{Core.Codec.PluginTest.NestedAbove.X, a: [type: :string]}],
              union: Core.Codec.PluginTest.NestedAbove,
              variants: [{Core.Codec.PluginTest.NestedAbove.Y, "y", b: [type: :string]}]
          end
        end
      )

    y = struct(Module.concat(mod, Y), b: "b")
    assert mod.dump(struct(Module.concat(mod, X), a: "a"), nil) == %{"a" => "a"}
    assert {:ok, ^y} = mod.load(mod, mod.dump(y, nil), nil)
  end
end
