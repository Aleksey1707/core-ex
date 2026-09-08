defmodule Core.GuardTest do
  use ExUnit.Case, async: true

  defmodule SampleEnum do
    @moduledoc false

    use Core.Enum,
      name: "Тестовый статус",
      values: ~w(new done)a
  end

  defmodule NotAnEnum do
    @moduledoc false

    def values, do: [1, 2]
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

    def enum_full(value) when is_enum(value, SampleEnum), do: :ok
    def enum_full(_value), do: :no

    def enum_subset(value) when in_enum(value, SampleEnum, ~w(new)a), do: :ok
    def enum_subset(_value), do: :no

    def prim(value) when is(value, SamplePrim), do: :ok
    def prim(_value), do: :no

    def prim_opt(value) when is_opt(value, SamplePrim), do: :ok
    def prim_opt(_value), do: :no

    def plain_map?(value) when is_plain_map(value), do: true
    def plain_map?(_value), do: false

    def json?(value) when is_json(value), do: true
    def json?(_value), do: false
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

  test "is_plain_map/1" do
    assert Matchers.plain_map?(%{a: 1})
    assert Matchers.plain_map?(%{})
    refute Matchers.plain_map?(%SamplePrim{value: 1})
    refute Matchers.plain_map?([{:a, 1}])
  end

  test "is_json/1 — только верхний уровень" do
    assert Matchers.json?("s")
    assert Matchers.json?(1)
    assert Matchers.json?(nil)
    assert Matchers.json?(true)
    assert Matchers.json?(%{"a" => 1})
    assert Matchers.json?([{:a, 1}])
    refute Matchers.json?(:atom)
    refute Matchers.json?(%SamplePrim{value: 1})
  end

  test "in_enum CompileError на неизвестный атом" do
    assert_raise CompileError, ~r/не входит в enum/, fn ->
      compile(
        quote do
          def f(x)
              when in_enum(x, Core.GuardTest.SampleEnum, ~w(new failed)a),
              do: x
        end
      )
    end
  end

  test "in_enum CompileError на дубль в subset" do
    assert_raise CompileError, ~r/не должен содержать дублей/, fn ->
      compile(
        quote do
          def f(x) when in_enum(x, Core.GuardTest.SampleEnum, ~w(new new)a), do: x
        end
      )
    end
  end

  test "in_enum CompileError на пустой subset" do
    assert_raise CompileError, ~r/непустым списком атомов/, fn ->
      compile(
        quote do
          def f(x) when in_enum(x, Core.GuardTest.SampleEnum, []), do: x
        end
      )
    end
  end

  test "is_enum CompileError на не-enum модуль" do
    assert_raise CompileError, ~r/не является модулем Core.Enum/, fn ->
      compile(
        quote do
          def f(x) when is_enum(x, String), do: x
        end
      )
    end
  end

  test "is_enum CompileError на values/0 не из атомов" do
    assert_raise CompileError, ~r/должна возвращать непустой список атомов/, fn ->
      compile(
        quote do
          def f(x) when is_enum(x, Core.GuardTest.NotAnEnum), do: x
        end
      )
    end
  end

  test "is_enum CompileError на не-модуль" do
    assert_raise CompileError, ~r/ожидался алиас модуля или атом/, fn ->
      compile(
        quote do
          def f(x) when is_enum(x, "SampleEnum"), do: x
        end
      )
    end
  end

  test "is_prim/1" do
    assert Matchers.prim?(%SamplePrim{value: "значение"})
    refute Matchers.prim?(%{value: 1})
    refute Matchers.prim?(:atom)
  end

  test "is_enum регистрирует исходник enum как external_resource каллера" do
    [{mod, _bin}] =
      compile(
        quote do
          def f(x) when is_enum(x, Core.GuardTest.SampleEnum), do: x
        end
      )

    sources = Keyword.get_values(mod.module_info(:attributes), :external_resource)

    assert Enum.any?(List.flatten(sources), &String.ends_with?(&1, "guard_test.exs"))
  end

  # ---

  defp compile(body) do
    name = Module.concat(Core.GuardTest, "Probe#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          @moduledoc false

          import Core.Guard

          unquote(body)
        end
      end
    )
  end
end
