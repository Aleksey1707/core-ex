defmodule Core.ContextTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Error
  alias Core.Exc

  test "new/0 creates empty context" do
    assert %Context{data: %{}} = Context.new()
  end

  test "new/1 creates context with data" do
    assert %Context{data: %{a: 1}} = Context.new(%{a: 1})
  end

  test "exists?/2, find/2, put/3, delete/2" do
    ctx = Context.new() |> Context.put(:a, 1)

    assert Context.exists?(ctx, :a)
    refute Context.exists?(ctx, :b)
    assert Context.find(ctx, :a) == 1
    assert Context.find(ctx, :b) == nil

    ctx = Context.delete(ctx, :a)
    refute Context.exists?(ctx, :a)
  end

  test "get/2 returns ok or error" do
    ctx = Context.new(%{a: 1})

    assert {:ok, 1} = Context.get(ctx, :a)
    assert {:error, %Error{code: :not_found}} = Context.get(ctx, :missing)
  end

  test "get!/2 raises on missing key" do
    assert_raise Exc, fn ->
      Context.get!(Context.new(), :missing)
    end
  end

  test "сохранённый nil отличим от отсутствующего ключа" do
    context = Context.new() |> Context.put(:maybe, nil)

    assert Context.exists?(context, :maybe)
    assert Context.get(context, :maybe) == {:ok, nil}

    refute Context.exists?(context, :absent)
    assert {:error, %Core.Error{code: :not_found}} = Context.get(context, :absent)
  end
end
