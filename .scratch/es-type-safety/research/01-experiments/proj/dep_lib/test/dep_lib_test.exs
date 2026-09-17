defmodule DepLibTest do
  use ExUnit.Case
  doctest DepLib

  test "greets the world" do
    assert DepLib.hello() == :world
  end
end
