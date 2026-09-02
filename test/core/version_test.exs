defmodule Core.VersionTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Version

  test "new/0 is 1" do
    assert %Version{value: 1} = Version.new()
  end

  test "new!/1 and value/1" do
    assert 42 = Version.value(Version.new!(42))
  end

  test "rejects below min" do
    assert {:error, %Error{kind: :domain, message: "Версия: минимум 1"}} = Version.new(0)
  end

  test "next/1 increments" do
    assert Version.next(Version.new!(2)) == Version.new!(3)
  end

  test "parse/1: * → :current" do
    assert {:ok, :current} = Version.parse("*")
  end

  test "parse/1: integer → Version" do
    assert {:ok, %Version{value: 3}} = Version.parse(3)
    assert {:ok, %Version{value: 3}} = Version.parse("3")
  end

  test "parse/1: invalid" do
    assert {:error, %Error{kind: :domain}} = Version.parse("x")
    assert {:error, %Error{kind: :domain}} = Version.parse(0)
  end

  test "parse!/1 разбирает или поднимает" do
    assert Version.parse!("*") == :current
    assert Version.value(Version.parse!(3)) == 3
    assert_raise Core.Exc, fn -> Version.parse!(0) end
  end
end
