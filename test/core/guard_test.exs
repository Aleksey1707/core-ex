defmodule Core.GuardTest do
  use ExUnit.Case, async: true

  alias Core.Error

  require Error

  defmodule SampleEnum do
    @moduledoc false

    use Core.Enum,
      name: "Тестовый статус",
      values: ~w(new done)a
  end

  defmodule SamplePrim do
    @moduledoc false
    defstruct [:value]
  end

  defmodule Matchers do
    @moduledoc false

    import Core.Guard

    alias Core.GuardTest.SampleEnum
    alias Core.GuardTest.SamplePrim

    def prim?(value) when is_prim(value), do: true
    def prim?(_value), do: false

    def error?(value) when is_error(value), do: true
    def error?(_value), do: false

    def enum_full(value) when is_enum(value, SampleEnum), do: :ok
    def enum_full(_value), do: :no

    def enum_subset(value) when in_enum(value, SampleEnum, ~w(new)a), do: :ok
    def enum_subset(_value), do: :no

    def prim(value) when is(value, SamplePrim), do: :ok
    def prim(_value), do: :no

    def prim_opt(value) when is_opt(value, SamplePrim), do: :ok
    def prim_opt(_value), do: :no
  end

  test "is_enum/2" do
    assert Matchers.enum_full(:new) == :ok
    assert Matchers.enum_full(:done) == :ok
    assert Matchers.enum_full(:failed) == :no
    assert Matchers.enum_full("new") == :no
  end

  test "in_enum/3" do
    assert Matchers.enum_subset(:new) == :ok
    assert Matchers.enum_subset(:done) == :no
  end

  test "is/2 и is_opt/2" do
    assert Matchers.prim(%SamplePrim{value: 1}) == :ok
    assert Matchers.prim(nil) == :no
    assert Matchers.prim_opt(%SamplePrim{value: 1}) == :ok
    assert Matchers.prim_opt(nil) == :ok
    assert Matchers.prim_opt(:x) == :no
  end

  test "in_enum CompileError на неизвестный атом" do
    assert_raise CompileError, ~r/не входит в enum/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Core.GuardTest.BadSubset do
            import Core.Guard

            def f(x)
                when in_enum(x, Core.GuardTest.SampleEnum, ~w(new failed)a),
                do: x
          end
        end
      )
    end
  end

  test "in_enum CompileError на пустой subset" do
    assert_raise CompileError, ~r/non-empty list of atoms/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Core.GuardTest.EmptySubset do
            import Core.Guard

            def f(x) when in_enum(x, Core.GuardTest.SampleEnum, []), do: x
          end
        end
      )
    end
  end

  test "is_enum CompileError на не-enum модуль" do
    assert_raise CompileError, ~r/not a Core.Enum/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Core.GuardTest.NotEnum do
            import Core.Guard

            def f(x) when is_enum(x, String), do: x
          end
        end
      )
    end
  end

  test "is_prim/1 и is_error/1" do
    prim = %SamplePrim{value: "значение"}

    assert Matchers.prim?(prim)
    refute Matchers.prim?(%{value: 1})
    refute Matchers.prim?(:atom)

    assert Matchers.error?(Error.app(code: :x, ns: :test))
    refute Matchers.error?(prim)
  end
end
