defmodule Core.OptionTest do
  use ExUnit.Case, async: true

  alias Core.Option
  alias Core.Result

  test "map/2 returns nil for nil" do
    assert Option.map(nil, &String.upcase/1) == nil
  end

  test "map/2 applies function to value" do
    assert Option.map("abc", &String.upcase/1) == "ABC"
  end

  test "some?/1" do
    assert Option.some?(1)
    refute Option.some?(nil)
  end

  test "or_/2" do
    assert Option.or_(1, 2) == 1
    assert Option.or_(nil, 2) == 2
  end

  test "or_else/2" do
    assert Option.or_else(1, fn -> 2 end) == 1
    assert Option.or_else(nil, fn -> 2 end) == 2
  end

  test "unwrap_or/2" do
    assert Option.unwrap_or(1, 0) == 1
    assert Option.unwrap_or(nil, 0) == 0
  end

  test "unwrap_or_else/2" do
    assert Option.unwrap_or_else(1, fn -> 0 end) == 1
    assert Option.unwrap_or_else(nil, fn -> 0 end) == 0
  end

  test "unwrap!/1" do
    assert Option.unwrap!(1) == 1

    assert_raise ArgumentError, fn ->
      Option.unwrap!(nil)
    end
  end

  test "expect!/2" do
    assert Option.expect!(1, "missing") == 1

    assert_raise RuntimeError, "missing", fn ->
      Option.expect!(nil, "missing")
    end
  end

  test "to_result/1" do
    assert Option.to_result(1) == Result.ok(1)
    assert Option.to_result(nil) == Result.error(:none)
  end

  test "to_unit/1" do
    assert Option.to_unit(1) == Result.ok()
    assert Option.to_unit(nil) == Result.error(:none)
    assert Option.to_unit(:ok) == Result.ok()
  end
end
