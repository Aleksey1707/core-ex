defmodule Core.Labels.IDTest do
  use ExUnit.Case, async: true

  alias Core.Labels.ID
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.Resolver
  alias Core.LabelsFixture.SnapshotID
  alias Core.LabelsFixture.UserID

  test "find/1 — объявление вида id" do
    assert ID.find(ItemID) == %{kind: :ref, entity: :stock_item, resolver: Resolver}
    assert ID.find(UserID) == %{kind: :user, entity: nil, resolver: Resolver}
    assert ID.find(SnapshotID) == %{kind: :id, entity: nil, resolver: nil}
  end

  test "find/1 — nil у Prim без объявления и у модуля без Prim" do
    assert ID.find(Name) == nil
    assert ID.find(URI) == nil
  end

  describe "отказ сборки" do
    test "kind: вне ~w(ref user id)a — CompileError" do
      assert_raise CompileError, ~r/Labels.ID .*Other: kind: — один из \[:ref, :user, :id\], задано :link/, fn ->
        compile_id(:Other, kind: :link)
      end
    end

    test "без kind: — CompileError" do
      assert_raise CompileError, ~r/Labels.ID: нет обязательных опций: \[:kind\]/, fn ->
        compile_id(:NoKind, entity: :item)
      end
    end

    test ":ref без entity: — CompileError" do
      assert_raise CompileError, ~r/NoEntity: `kind: :ref` без `entity:`/, fn ->
        compile_id(:NoEntity, kind: :ref, resolver: Resolver)
      end
    end

    test ":ref с entity: не атомом — CompileError" do
      assert_raise CompileError, ~r/StringEntity: entity: — атом вида записи, задано "stockItem"/, fn ->
        compile_id(:StringEntity, kind: :ref, entity: "stockItem", resolver: Resolver)
      end
    end

    test ":ref без resolver: — CompileError" do
      assert_raise CompileError, ~r/NoResolver: вид id со ссылкой без `resolver:`/, fn ->
        compile_id(:NoResolver, kind: :ref, entity: :item)
      end
    end

    test ":user без resolver: — CompileError" do
      assert_raise CompileError, ~r/UserNoResolver: вид id со ссылкой без `resolver:`/, fn ->
        compile_id(:UserNoResolver, kind: :user)
      end
    end

    test "resolver: не модулем — CompileError" do
      assert_raise CompileError, ~r/AtomResolver: resolver: — модуль, задано :names/, fn ->
        compile_id(:AtomResolver, kind: :user, resolver: :names)
      end
    end

    test ":user с entity: — CompileError" do
      assert_raise CompileError, ~r/UserEntity: `entity:` у `kind: :user` не задаётся/, fn ->
        compile_id(:UserEntity, kind: :user, entity: :item, resolver: Resolver)
      end
    end

    test ":id с resolver: — CompileError" do
      assert_raise CompileError, ~r/IdResolver: `resolver:` у `kind: :id` не задаётся/, fn ->
        compile_id(:IdResolver, kind: :id, resolver: Resolver)
      end
    end

    test ":id с entity: — CompileError" do
      assert_raise CompileError, ~r/IdEntity: `entity:` у `kind: :id` не задаётся/, fn ->
        compile_id(:IdEntity, kind: :id, entity: :item)
      end
    end

    test "неизвестная опция — CompileError" do
      assert_raise CompileError, ~r/Labels.ID: неизвестные опции: \[:name\]/, fn ->
        compile_id(:Unknown, kind: :id, name: "Id")
      end
    end

    test "модуль без use Core.Prim — CompileError" do
      assert_raise CompileError, ~r/NotPrim: не Prim: `use Core.Labels.ID` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.IDTest.NotPrim do
              use Core.Labels.ID, kind: :id
            end
          end
        )
      end
    end

    test "вместе с Core.Labels.Text — CompileError" do
      assert_raise CompileError, ~r/WithText: `use Core.Labels.ID` и `use Core.Labels.Text` вместе/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.IDTest.WithText do
              use Core.Prim.UUID, name: "Id", version: 7

              use Core.Labels.Text, with: &Kernel.inspect/1

              use Core.Labels.ID, kind: :id
            end
          end
        )
      end
    end
  end

  # ---

  defp compile_id(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Prim.UUID, name: "Id", version: 7

          use Core.Labels.ID, unquote(opts)
        end
      end
    )
  end
end
