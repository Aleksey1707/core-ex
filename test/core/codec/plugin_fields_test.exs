defmodule Core.Codec.PluginFieldsTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Prim
  alias Core.PrimFixture
  alias Core.Version

  defmodule Name do
    use Prim.String, name: "Имя", min_len: 1, max_len: 50
  end

  defmodule ID do
    use Prim.UUID, name: "ID", version: 4
  end

  defmodule OwnerID do
    use Prim.Compose, name: "Владелец", of: ID
  end

  defmodule Item do
    defstruct [:id, :name, :owner_id, :secret, :version, :note, events: []]
  end

  defmodule Tag do
    defstruct [:name]
  end

  defmodule Plugin do
    use Core.Codec.Plugin,
      types: [Item, Tag],
      fields: [
        {Item,
         id: [prim: ID],
         name: [prim: Name, wire: "title"],
         owner_id: [prim: OwnerID],
         secret: [prim: PrimFixture.Password],
         version: [prim: Version],
         note: [prim: Name, optional: true]},
        {Tag, name: [prim: Name]}
      ]
  end

  defmodule Facade do
    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [Plugin]
  end

  setup do
    item = %Item{
      id: ID.new!("6f1f8b8e-6b5a-4c47-9d5e-0b7c1d0e8f11"),
      name: Name.new!("Стол"),
      owner_id: OwnerID.new!("1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d"),
      secret: PrimFixture.Password.new!("secret-password"),
      version: Version.new!(3),
      note: nil
    }

    %{item: item}
  end

  test "dump даёт wire-map по полям, ключ — wire: или имя поля", %{item: item} do
    assert Facade.dump(item) == %{
             "id" => "6f1f8b8e-6b5a-4c47-9d5e-0b7c1d0e8f11",
             "title" => "Стол",
             "owner_id" => "1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
             "secret" => "secret-password",
             "version" => 3,
             "note" => nil
           }
  end

  test "round-trip через фасад", %{item: item} do
    assert Facade.load(Item, Facade.dump(item)) == {:ok, item}

    item = %{item | note: Name.new!("у окна")}
    assert Facade.load(Item, Facade.dump(item)) == {:ok, item}
    assert Facade.load(Tag, Facade.dump(%Tag{name: Name.new!("x")})) == {:ok, %Tag{name: Name.new!("x")}}
  end

  test "optional: отсутствующий ключ — nil", %{item: item} do
    wire = Map.delete(Facade.dump(item), "note")

    assert {:ok, %Item{note: nil}} = Facade.load(Item, wire)
  end

  test "чтение по wire: и атомарным ключам, лишние ключи игнорируются", %{item: item} do
    wire =
      item
      |> Facade.dump()
      |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
      |> Map.put(:unknown, "x")

    assert Facade.load(Item, wire) == {:ok, item}
  end

  test "первая ошибка поля — итог", %{item: item} do
    wire = %{Facade.dump(item) | "id" => "not-uuid", "title" => ""}

    assert {:error, %Error{module: ID}} = Facade.load(Item, wire)
  end

  test "обязательное поле без ключа — ошибка его Prim", %{item: item} do
    wire = Map.delete(Facade.dump(item), "title")

    assert {:error, %Error{module: Name}} = Facade.load(Item, wire)
  end

  test "значение не того Prim — FunctionClauseError", %{item: item} do
    assert_raise FunctionClauseError, fn -> Facade.dump(%{item | name: "Стол"}) end
    assert_raise FunctionClauseError, fn -> Facade.dump(%{item | note: "у окна"}) end
  end

  describe "сборка" do
    test "поле struct без спеки и поле спеки без struct — CompileError" do
      assert_raise CompileError, ~r/поля struct без спеки \[:b\], поля спеки без struct \[:c\]/, fn ->
        compile_plugin(:StructMismatch, a: [prim: Name], c: [prim: Name])
      end
    end

    test "ключ fields: вне types: — CompileError" do
      assert_raise CompileError, ~r/типы вне types:/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginFieldsTest.Foreign do
              use Core.Codec.Plugin,
                types: [Core.Codec.PluginFieldsTest.Tag],
                fields: [{Core.Codec.PluginFieldsTest.Item, id: [prim: Core.Codec.PluginFieldsTest.ID]}]
            end
          end
        )
      end
    end

    test "тип объявлен дважды — CompileError" do
      assert_raise CompileError, ~r/типы объявлены дважды/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Codec.PluginFieldsTest.Twice do
              use Core.Codec.Plugin,
                types: [Core.Codec.PluginFieldsTest.Tag],
                fields: [
                  {Core.Codec.PluginFieldsTest.Tag, name: [prim: Core.Codec.PluginFieldsTest.Name]},
                  {Core.Codec.PluginFieldsTest.Tag, name: [prim: Core.Codec.PluginFieldsTest.Name]}
                ]
            end
          end
        )
      end
    end

    test "не Prim в prim: — CompileError с именем плагина, типа и поля" do
      message = ~r/Codec.Plugin .*NotPrim: fields:, тип .*NotPrim.T, поле b: .*Tag не Prim/

      assert_raise CompileError, message, fn ->
        compile_plugin(:NotPrim, a: [prim: Name], b: [prim: Core.Codec.PluginFieldsTest.Tag])
      end
    end

    test "повтор поля и повтор wire-ключа — CompileError" do
      assert_raise CompileError, ~r/поля повторяются: \[:a\]/, fn ->
        compile_plugin(:DupField, a: [prim: Name], a: [prim: Name, wire: "b"])
      end

      assert_raise CompileError, ~r/wire-ключи повторяются: \["b"\]/, fn ->
        compile_plugin(:DupWire, a: [prim: Name, wire: "b"], b: [prim: Name])
      end
    end

    test "неизвестный ключ спеки — CompileError" do
      assert_raise CompileError, ~r/поле a: неизвестные ключи \[:default_value\]/, fn ->
        compile_plugin(:UnknownKey, a: [prim: Name, default_value: 1], b: [prim: Name])
      end
    end
  end

  # ---

  defp compile_plugin(name, spec) do
    plugin = Module.concat(__MODULE__, name)
    type = Module.concat(plugin, T)
    spec = Macro.escape(spec)

    Code.eval_quoted(
      quote do
        defmodule unquote(plugin) do
          defmodule unquote(type) do
            defstruct [:a, :b]
          end

          use Core.Codec.Plugin,
            types: [unquote(type)],
            fields: [{unquote(type), unquote(spec)}]
        end
      end
    )
  end
end
