defmodule Core.Helper.FieldCheckTest do
  use ExUnit.Case, async: true

  alias Core.Helper.FieldCheck
  alias Core.ViewFixture

  @where "Декларация, поле x"

  describe "module!/2" do
    test "собранный модуль проходит" do
      assert FieldCheck.module!(ViewFixture.Name, @where) == :ok
    end

    test "несуществующий модуль — CompileError с причиной" do
      assert_raise CompileError, ~r/Декларация, поле x: Core.Nope недоступен \(nofile\)/, fn ->
        FieldCheck.module!(Core.Nope, @where)
      end
    end

    test "не модуль — CompileError" do
      assert_raise CompileError, ~r/Декларация, поле x: ожидался модуль, задано "name"/, fn ->
        FieldCheck.module!("name", @where)
      end
    end
  end

  describe "prim!/2" do
    test "Prim проходит" do
      assert FieldCheck.prim!(ViewFixture.Name, @where) == :ok
    end

    test "не Prim — CompileError" do
      assert_raise CompileError, ~r/Декларация, поле x: Core.ViewFixture.Status не Prim/, fn ->
        FieldCheck.prim!(ViewFixture.Status, @where)
      end
    end

    test "несуществующий модуль — CompileError доступности" do
      assert_raise CompileError, ~r/недоступен/, fn -> FieldCheck.prim!(Core.Nope, @where) end
    end
  end

  describe "enum!/2" do
    test "Core.Enum проходит" do
      assert FieldCheck.enum!(ViewFixture.Status, @where) == :ok
    end

    test "не Core.Enum — CompileError" do
      assert_raise CompileError, ~r/Декларация, поле x: Core.ViewFixture.Name не Core.Enum/, fn ->
        FieldCheck.enum!(ViewFixture.Name, @where)
      end
    end

    test "несуществующий модуль — CompileError доступности" do
      assert_raise CompileError, ~r/недоступен/, fn -> FieldCheck.enum!(Core.Nope, @where) end
    end
  end

  describe "unique!/2" do
    test "без повторов — :ok" do
      assert FieldCheck.unique!([:a, :b], "Декларация") == :ok
    end

    test "повторы — CompileError, каждый повтор один раз" do
      assert_raise CompileError, ~r/^Декларация: повторяются \[:a, "b"\]$/, fn ->
        FieldCheck.unique!([:a, "b", :a, "b", :a, :c], "Декларация")
      end
    end
  end
end
