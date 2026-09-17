defmodule App.TypesTest do
  use ExUnit.Case, async: true

  defp helper(x) when is_integer(x), do: x

  test "wrong arg to lib function" do
    assert_raise FunctionClauseError, fn -> App.Local.to_int("x") end
  end

  test "wrong arg to local helper" do
    assert_raise FunctionClauseError, fn -> helper("x") end
  end

  test "direct call outside fn" do
    value = "x"
    assert_raise FunctionClauseError, fn -> App.Local.to_int(value) end
  end
end
