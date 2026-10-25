defmodule Core.Es.Projection.WaitOptionTest do
  use ExUnit.Case, async: true

  defmodule Usecase do
    @moduledoc false

    use Core.Options

    @opts_schema [wait: Core.Es.Projection.wait_option()]
    def change(opts \\ []) when is_list(opts), do: Keyword.fetch!(opts, :wait)
  end

  describe "wait_option/0" do
    test "без опции — :none" do
      assert Usecase.change() == :none
    end

    test ":none и положительное целое — принимаются" do
      assert Usecase.change(wait: :none) == :none
      assert Usecase.change(wait: 1500) == 1500
    end

    test "ноль, отрицательное и не целое — ArgumentError" do
      for wait <- [0, -1, :infinity, 1.5] do
        assert_raise ArgumentError, ~r/:wait/, fn -> Usecase.change(wait: wait) end
      end
    end
  end
end
