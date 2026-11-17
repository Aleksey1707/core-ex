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

  defmodule DeclaredStatus do
    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  defmodule DeclaredName do
    use Core.Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Declared do
    use Core.Struct,
      fields: [
        name: [prim: Core.Codec.PluginTest.DeclaredName, wire: "title"],
        note: [prim: Core.Codec.PluginTest.DeclaredName, optional: true],
        status: [enum: Core.Codec.PluginTest.DeclaredStatus, default: :new],
        tags: [list: [prim: Core.Codec.PluginTest.DeclaredName], default: []],
        owner: [prim: Core.Codec.PluginTest.DeclaredName]
      ]
  end

  defmodule DeclaredPlugin do
    use Core.Codec.Plugin, types: [Declared]
  end

  defmodule PersonalPlugin do
    use Core.Codec.Plugin, types: [Core.StructFixture.Recipient]
  end

  defmodule DeclaredDumpOnly do
    use Core.Codec.Plugin,
      types: [Declared],
      loadable: false
  end

  @codec Core.CodecFixture.Prim.Internal

  describe "декларативный тип" do
    test "dump/2 и load/3 по __core_fields__: wire, optional, typed default" do
      value = %Declared{
        name: DeclaredName.new!("Стол"),
        note: nil,
        status: :new,
        tags: [],
        owner: DeclaredName.new!("Склад")
      }

      assert DeclaredPlugin.dump(value, @codec) == %{
               "title" => "Стол",
               "note" => nil,
               "status" => :new,
               "tags" => [],
               "owner" => "Склад"
             }

      wire = Map.drop(DeclaredPlugin.dump(value, @codec), ~w(note status tags))

      assert DeclaredPlugin.load(Declared, wire, @codec) ==
               {:ok, %{value | note: nil, status: :new, tags: []}}
    end

    test "явный null не заменяется default: у обязательного поля — ошибка загрузки" do
      wire = %{"title" => "Стол", "status" => nil, "owner" => "Склад"}

      assert {:error, %Core.Error{}} = DeclaredPlugin.load(Declared, wire, @codec)
    end

    test "personal: на Codec не влияет — значение остаётся открытым" do
      value = %Core.StructFixture.Recipient{
        phone: Core.StructFixture.Name.new!("+7 900"),
        label: Core.StructFixture.Name.new!("дом")
      }

      assert PersonalPlugin.dump(value, @codec) == %{"phone" => "+7 900", "label" => "дом"}

      assert PersonalPlugin.load(Core.StructFixture.Recipient, %{"phone" => "+7 900", "label" => "дом"}, @codec) ==
               {:ok, value}
    end

    test "loadable: false — dump есть, load/3 не порождается" do
      assert Core.Helper.Module.exports?(DeclaredDumpOnly, :dump, 2)
      refute Core.Helper.Module.exports?(DeclaredDumpOnly, :load, 3)
    end

    test "ручная клауза на декларативный тип — CompileError never match" do
      assert_raise CompileError, ~r/never match — dump\/2 для .*DeadDeclared\.D/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginTest.DeadDeclared do
              defmodule D do
                use Core.Struct, fields: [a: [type: :string]]
              end

              use Core.Codec.Plugin, types: [Core.Codec.PluginTest.DeadDeclared.D]

              @impl true
              def dump(%Core.Codec.PluginTest.DeadDeclared.D{a: a}, _codec), do: %{"a" => a}
            end
          end
        )
      end
    end
  end

  test "fields: и variants: — неизвестные опции" do
    for {opts, key} <- [
          {[types: [Core.Version], fields: []], :fields},
          {[types: [Core.Version], variants: []], :variants}
        ] do
      {:ok, env} = Macro.Env.define_require(__ENV__, [], Core.Codec.Plugin)

      assert_raise CompileError, ~r/^Codec\.Plugin: неизвестные опции: \[#{inspect(key)}\]$/, fn ->
        Macro.expand(quote(do: Core.Codec.Plugin.__using__(unquote(opts))), env)
      end
    end
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
    assert_raise CompileError, ~r/нет типов — задайте types: или union: с составом семейства/, fn ->
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
    assert_raise CompileError, ~r/^Codec\.Plugin: union: ожидается литерал, получено @family$/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.AttrUnion do
            @family Core.Codec.PluginTest.AttrUnion
            use Core.Codec.Plugin,
              types: [Core.Version],
              union: @family
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
            use Core.Codec.Plugin,
              types: Map.keys(@types),
              loadable: false

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
            use Core.Codec.Plugin,
              types: @types,
              loadable: false
          end
        end
      )
    end
  end

  test "декларативный тип ниже use не виден — требуется ручная клауза dump/2" do
    assert_raise CompileError, ~r/требуется dump\/2 для \[.*NestedBelow\.X\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NestedBelow do
            use Core.Codec.Plugin, types: [Core.Codec.PluginTest.NestedBelow.X]

            defmodule X do
              use Core.Struct, fields: [a: [type: :string]]
            end
          end
        end
      )
    end
  end

  test "вложенные выше use декларативный тип и семейство собираются" do
    {{:module, mod, _bin, _}, _binding} =
      Code.eval_quoted(
        quote do
          defmodule Core.Codec.PluginTest.NestedAbove do
            defmodule X do
              use Core.Struct, fields: [a: [type: :string]]
            end

            defmodule Y do
              use Core.Struct, fields: [b: [type: :string]]
            end

            defmodule Family do
              use Core.Union, variants: [{Core.Codec.PluginTest.NestedAbove.Y, "y"}]
            end

            use Core.Codec.Plugin,
              types: [Core.Codec.PluginTest.NestedAbove.X],
              union: Core.Codec.PluginTest.NestedAbove.Family
          end
        end
      )

    codec = Core.CodecFixture.Prim.Internal
    y = struct(Module.concat(mod, Y), b: "b")

    assert mod.dump(struct(Module.concat(mod, X), a: "a"), codec) == %{"a" => "a"}
    assert {:ok, ^y} = mod.load(Module.concat(mod, Family), mod.dump(y, codec), codec)
  end
end
