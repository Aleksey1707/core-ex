defmodule Core.ResultTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Exc
  alias Core.Option
  alias Core.Result

  require Error

  # Process.get/1 → dynamic(); намеренный misuse unit без type warning
  defp unit_ok do
    Process.put({__MODULE__, :unit_ok}, Result.ok())
    Process.get({__MODULE__, :unit_ok})
  end

  # Process.get/1 → dynamic(); намеренный misuse чужим термом без type warning
  defp alien do
    Process.put({__MODULE__, :alien}, :whatever)
    Process.get({__MODULE__, :alien})
  end

  defp domain_error(n), do: Error.domain(code: :invalid, ns: :test, message: "e#{n}")

  test "map/2" do
    assert Result.map(Result.ok(1), &(&1 + 1)) == Result.ok(2)
    assert Result.map(Result.error(:e), &(&1 + 1)) == Result.error(:e)
  end

  test "map_or/3 returns bare value" do
    assert Result.map_or(Result.ok(1), 0, &(&1 + 1)) == 2
    assert Result.map_or(Result.error(:e), 0, &(&1 + 1)) == 0
  end

  test "map_or_else/3 returns bare value and uses reason" do
    assert Result.map_or_else(Result.ok(1), fn _ -> 0 end, &(&1 + 1)) == 2
    assert Result.map_or_else(Result.error(:e), &to_string/1, &(&1 + 1)) == "e"
  end

  test "and_/2" do
    assert Result.and_(Result.ok(1), Result.ok(2)) == Result.ok(2)
    assert Result.and_(Result.error(:e), Result.ok(2)) == Result.error(:e)
    assert Result.and_(Result.ok(), Result.ok(2)) == Result.ok(2)
    assert Result.and_(Result.ok(), Result.ok()) == Result.ok()
  end

  test "and_then/2" do
    assert Result.and_then(Result.ok(1), &Result.ok(&1 + 1)) == Result.ok(2)
    assert Result.and_then(Result.error(:e), &Result.ok(&1 + 1)) == Result.error(:e)
  end

  test "traverse/2 preserves order and empty list" do
    assert Result.traverse([], &Result.ok/1) == Result.ok([])
    assert Result.traverse([1, 2, 3], &Result.ok(&1 * 2)) == Result.ok([2, 4, 6])
  end

  test "traverse/2 halts on first error and skips rest" do
    parent = self()

    fun = fn
      2 ->
        send(parent, :called_2)
        Result.error(:e)

      n ->
        send(parent, {:called, n})
        Result.ok(n)
    end

    assert Result.traverse([1, 2, 3], fun) == Result.error(:e)
    assert_received {:called, 1}
    assert_received :called_2
    refute_received {:called, 3}
  end

  test "traverse/2 rejects non-list at runtime" do
    # Process.get/1 → dynamic(); намеренный misuse без type warning
    Process.put({__MODULE__, :not_a_list}, :not_a_list)
    not_a_list = Process.get({__MODULE__, :not_a_list})

    assert_raise FunctionClauseError, fn ->
      Result.traverse(not_a_list, &Result.ok/1)
    end
  end

  test "traverse_all/2 preserves order and empty list" do
    assert Result.traverse_all([], &Result.ok/1) == Result.ok([])
    assert Result.traverse_all([1, 2, 3], &Result.ok(&1 * 2)) == Result.ok([2, 4, 6])
  end

  test "traverse_all/2 collects every error in input order" do
    assert {:error, errors} = Result.traverse_all([1, 2, 3], &Result.error(domain_error(&1)))
    assert Enum.map(errors, &to_string/1) == ["e1", "e2", "e3"]
  end

  test "traverse_all/2 walks the whole list and returns failures only" do
    parent = self()

    fun = fn n ->
      send(parent, {:called, n})

      if rem(n, 2) == 0,
        do: Result.error(domain_error(n)),
        else: Result.ok(n)
    end

    assert {:error, errors} = Result.traverse_all([1, 2, 3, 4], fun)
    assert Enum.map(errors, &to_string/1) == ["e2", "e4"]
    assert_received {:called, 1}
    assert_received {:called, 2}
    assert_received {:called, 3}
    assert_received {:called, 4}
  end

  test "traverse_all/2 collects a non-Error reason as is" do
    assert Result.traverse_all([1, 2], &Result.error({:bad, &1})) ==
             Result.error([{:bad, 1}, {:bad, 2}])
  end

  test "or_/2" do
    assert Result.or_(Result.ok(1), Result.ok(2)) == Result.ok(1)
    assert Result.or_(Result.error(:e), Result.ok(2)) == Result.ok(2)
    assert Result.or_(Result.ok(), Result.ok(2)) == Result.ok()
    assert Result.or_(Result.error(:e), Result.ok()) == Result.ok()
  end

  test "or_else/2" do
    assert Result.or_else(Result.ok(1), fn -> Result.ok(2) end) == Result.ok(1)
    assert Result.or_else(Result.error(:e), fn -> Result.ok(2) end) == Result.ok(2)
    assert Result.or_else(Result.ok(), fn -> Result.ok(2) end) == Result.ok()
    assert Result.or_else(Result.error(:e), fn -> Result.ok() end) == Result.ok()
  end

  test "unwrap!/1" do
    assert Result.unwrap!(Result.ok(1)) == 1

    assert_raise ArgumentError, fn ->
      Result.unwrap!(Result.error(:e))
    end

    error = Error.domain(__MODULE__, code: :test, ns: :test, message: "test")

    assert_raise Exc, fn ->
      Result.unwrap!(Result.error(error))
    end
  end

  test "unwrap_or/2" do
    assert Result.unwrap_or(Result.ok(1), 0) == 1
    assert Result.unwrap_or(Result.error(:e), 0) == 0
  end

  test "unwrap_or_else/2" do
    assert Result.unwrap_or_else(Result.ok(1), fn -> 0 end) == 1
    assert Result.unwrap_or_else(Result.error(:e), fn -> 0 end) == 0
  end

  test "ok/0, ok/1, error/1" do
    assert Result.ok() == :ok
    assert Result.ok(1) == {:ok, 1}
    assert Result.error(:e) == {:error, :e}
  end

  test "ok?/1 and error?/1" do
    assert Result.ok?(Result.ok(1))
    assert Result.ok?(Result.ok())
    refute Result.ok?(Result.error(:e))
    assert Result.error?(Result.error(:e))
    refute Result.error?(Result.ok(1))
    refute Result.error?(Result.ok())
  end

  test "to_option/1" do
    assert Result.to_option(Result.ok(1)) == 1
    assert Result.to_option(Result.error(:e)) == nil
    assert is_nil(Option.map(Result.to_option(Result.error(:e)), & &1))
  end

  test "value ops reject unit at runtime" do
    u = unit_ok()

    assert_raise FunctionClauseError, fn -> Result.map(u, &(&1 + 1)) end
    assert_raise FunctionClauseError, fn -> Result.map_or(u, 0, &(&1 + 1)) end
    assert_raise FunctionClauseError, fn -> Result.map_or_else(u, fn _ -> 0 end, &(&1 + 1)) end
    assert_raise FunctionClauseError, fn -> Result.and_then(u, fn _ -> Result.ok(1) end) end
    assert_raise FunctionClauseError, fn -> Result.unwrap!(u) end
    assert_raise FunctionClauseError, fn -> Result.unwrap_or(u, 0) end
    assert_raise FunctionClauseError, fn -> Result.unwrap_or_else(u, fn -> 0 end) end
    assert_raise FunctionClauseError, fn -> Result.to_option(u) end
  end

  test "map_error/2 обогащает только ошибку" do
    assert Result.map_error({:ok, 1}, fn _ -> :other end) == {:ok, 1}
    assert Result.map_error(:ok, fn _ -> :other end) == :ok
    assert Result.map_error({:error, :boom}, &{:wrapped, &1}) == {:error, {:wrapped, :boom}}
  end

  test "tap/2 выполняет эффект и возвращает исходный результат" do
    parent = self()

    assert Result.tap({:ok, 42}, &send(parent, {:seen, &1})) == {:ok, 42}
    assert_received {:seen, 42}

    assert Result.tap({:error, :boom}, &send(parent, {:seen, &1})) == {:error, :boom}
    refute_received {:seen, _}

    assert Result.tap(:ok, &send(parent, {:seen, &1})) == :ok
    refute_received {:seen, _}
  end

  test "map_error/2 and tap/2 reject alien term at runtime" do
    alien = alien()

    assert_raise FunctionClauseError, fn -> Result.map_error(alien, fn _ -> :other end) end
    assert_raise FunctionClauseError, fn -> Result.tap(alien, & &1) end
  end
end
