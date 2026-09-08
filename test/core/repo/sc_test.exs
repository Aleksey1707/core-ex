defmodule Core.Repo.ScTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Repo

  defmodule Entity do
    defstruct [:id, :name]
  end

  defmodule OtherEntity do
    defstruct [:id, :name]
  end

  test "init/put/fetch round-trip" do
    ctx = Context.new() |> Repo.Sc.init()
    entity = %Entity{id: "1", name: "a"}

    assert ^entity = Repo.Sc.put(ctx, entity)
    assert %Entity{id: "1", name: "a"} = Repo.Sc.find(ctx, Entity, "1")
  end

  test "разные сущности с одинаковым id не подменяют друг друга" do
    ctx = Context.new() |> Repo.Sc.init()
    entity = %Entity{id: "1", name: "a"}
    other = %OtherEntity{id: "1", name: "b"}

    Repo.Sc.put(ctx, entity)
    Repo.Sc.put(ctx, other)

    assert Repo.Sc.find(ctx, Entity, "1") == entity
    assert Repo.Sc.find(ctx, OtherEntity, "1") == other
  end

  test "повторный put перезаписывает эталон" do
    ctx = Context.new() |> Repo.Sc.init()
    first = %Entity{id: "1", name: "a"}
    second = %Entity{id: "1", name: "b"}

    Repo.Sc.put(ctx, first)
    Repo.Sc.put(ctx, second)

    assert Repo.Sc.find(ctx, Entity, "1") == second
  end

  test "put and fetch no-op without init" do
    ctx = Context.new()
    entity = %Entity{id: "1", name: "a"}

    assert ^entity = Repo.Sc.put(ctx, entity)
    assert Repo.Sc.find(ctx, Entity, "1") == nil
  end

  test "delete/1 удаляет таблицу, снимает ключ и идемпотентен" do
    ctx = Context.new() |> Repo.Sc.init()
    tid = Context.find(ctx, :shadow_copy)

    assert is_reference(tid)
    assert :ets.info(tid) != :undefined

    ctx = Repo.Sc.delete(ctx)

    assert :ets.info(tid) == :undefined
    refute Context.exists?(ctx, :shadow_copy)
    assert ^ctx = Repo.Sc.delete(ctx)
  end

  test "delete/1 no-op without init" do
    ctx = Context.new()

    assert ^ctx = Repo.Sc.delete(ctx)
  end

  test "delete/1 makes stored snapshot unavailable" do
    ctx = Context.new() |> Repo.Sc.init()
    entity = %Entity{id: "1", name: "a"}
    Repo.Sc.put(ctx, entity)
    tid = Context.find(ctx, :shadow_copy)

    assert Repo.Sc.find(ctx, Entity, "1") == entity

    ctx = Repo.Sc.delete(ctx)

    assert :ets.info(tid) == :undefined
    assert ^entity = Repo.Sc.put(ctx, entity)
    assert Repo.Sc.find(ctx, Entity, "1") == nil
  end

  test "clear/1 забывает эталоны, оставляя кэш рабочим" do
    ctx = Context.new() |> Repo.Sc.init()
    tid = Context.find(ctx, :shadow_copy)
    entity = %Entity{id: "1", name: "a"}
    Repo.Sc.put(ctx, entity)

    assert ^ctx = Repo.Sc.clear(ctx)
    assert :ets.info(tid) != :undefined
    assert Repo.Sc.find(ctx, Entity, "1") == nil

    assert ^entity = Repo.Sc.put(ctx, entity)
    assert Repo.Sc.find(ctx, Entity, "1") == entity
  end

  test "put/find на старой копии контекста после delete/1 — no-op" do
    stale = Context.new() |> Repo.Sc.init()
    entity = %Entity{id: "1", name: "a"}
    Repo.Sc.put(stale, entity)
    Repo.Sc.delete(stale)

    assert ^entity = Repo.Sc.put(stale, entity)
    assert Repo.Sc.find(stale, Entity, "1") == nil
  end

  test "clear/1 no-op без init и снимает мёртвый ключ после delete/1" do
    empty = Context.new()

    assert ^empty = Repo.Sc.clear(empty)

    stale = Context.new() |> Repo.Sc.init()
    Repo.Sc.delete(stale)

    assert Context.exists?(stale, :shadow_copy)
    refute Context.exists?(Repo.Sc.clear(stale), :shadow_copy)
  end
end
