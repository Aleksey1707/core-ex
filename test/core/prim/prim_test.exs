defmodule Core.PrimTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Core.Prim,
      name: "Число",
      kind: :integer,
      cast: &Core.PrimTest.cast_int/1,
      validate: &Core.PrimTest.validate_positive/2,
      custom_mutate: &Core.PrimTest.double/1,
      custom_validate: &Core.PrimTest.validate_even/1
  end

  def cast_int(n) when is_integer(n), do: {:ok, n}
  def cast_int(_), do: {:error, {:invalid_integer, "невалидное значение"}}

  def validate_positive(n, _opts) when n > 0, do: :ok
  def validate_positive(_n, _opts), do: {:error, {:not_positive, "должно быть положительным"}}

  def double(n), do: n * 2

  def validate_even(n) when rem(n, 2) == 0, do: :ok
  def validate_even(_), do: {:error, {:not_even, "должно быть чётным"}}

  test "new/1 returns ok struct after mutate" do
    assert {:ok, %Sample{value: 10}} = Sample.new(5)
  end

  test "prim?/1 detects Prim modules" do
    assert Core.Prim.prim?(Sample)
    refute Core.Prim.prim?(DateTime)
    refute Core.Prim.prim?(String)
  end

  test "prim?/1 loads module on demand" do
    mod = Core.PrimFixture.Purgeable
    {:module, ^mod} = Code.ensure_loaded(mod)

    :code.purge(mod)
    true = :code.delete(mod)
    :code.purge(mod)
    refute :erlang.module_loaded(mod)

    assert Core.Prim.prim?(mod)
  end

  test "new/1 returns domain error on cast" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              code: :invalid_integer,
              message: "Число: невалидное значение"
            }} = Sample.new("x")
  end

  test "new/1 returns domain error on validation" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              code: :not_positive,
              message: "Число: должно быть положительным"
            }} = Sample.new(-1)
  end

  test "new!/1 raises Exc" do
    assert_raise Core.Exc, fn -> Sample.new!("x") end
  end

  test "value/1, name/0 and __domain_kind__/0" do
    assert 10 = Sample.value(Sample.new!(5))
    assert "Число" = Sample.name()
    assert :integer = Sample.__domain_kind__()
  end

  test "__domain_type_opts__/0 without type_opts is empty" do
    assert [] = Sample.__domain_type_opts__()
  end

  test "requires :cast, :name and :kind" do
    assert_raise CompileError, ~r/missing required option\(s\)/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.PrimTest.NoCast do
            use Core.Prim, name: "X", kind: :integer
          end
        end
      )
    end
  end

  test "rejects error without detail" do
    defmodule BadValidate do
      use Core.Prim,
        name: "X",
        kind: :integer,
        cast: &Core.PrimTest.identity_cast/1,
        custom_validate: &Core.PrimTest.bad_validate/1
    end

    assert_raise ArgumentError,
                 ~r/domain error must be \{:error, \{code, detail\}\} or \{:error, %Error\{\}\}/,
                 fn ->
                   BadValidate.new(1)
                 end
  end

  test "wrapper rejects foreign builtin kind" do
    assert_raise ArgumentError, ~r/builtin kind/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.PrimTest.BadKind do
            use Core.Prim.UUID,
              name: "X",
              kind: :datetime
          end
        end
      )
    end
  end

  test "native_kinds/0 lists builtin kinds" do
    assert :uuid in Core.Prim.native_kinds()
    assert :datetime in Core.Prim.native_kinds()
  end

  test "reserved_kinds/0 includes :composite" do
    assert :composite in Core.Prim.reserved_kinds()
    assert :uuid in Core.Prim.reserved_kinds()
  end

  test "composed?/1 is false for plain Prim" do
    refute Core.Prim.composed?(Sample)
  end

  test "unwrap/1 returns leaf value" do
    assert 10 = Core.Prim.unwrap(Sample.new!(5))
  end

  test "normalize_ok passes through {:error, %Error{}}" do
    err =
      Core.Prim.wrap_error(__MODULE__, "X", :invalid, "причина", :detail)

    assert {:error, ^err} = Core.Prim.normalize_ok({:error, err})
  end

  test "cast returning %Error{} is wrapped via wrap_parent" do
    defmodule ErrorCast do
      use Core.Prim,
        name: "Обёртка",
        kind: :integer,
        cast: &Core.PrimTest.error_cast/1
    end

    assert {:error,
            %Core.Error{
              code: :boom,
              message: "Обёртка: внутренняя: причина",
              parent: %Core.Error{code: :boom, module: __MODULE__}
            }} = ErrorCast.new(1)
  end

  test "wrapper rejects reserved kind :composite" do
    assert_raise ArgumentError, ~r/builtin kind/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.PrimTest.CompositeKind do
            use Core.Prim.String,
              name: "X",
              kind: :composite
          end
        end
      )
    end
  end

  def identity_cast(v), do: {:ok, v}
  def bad_validate(_), do: {:error, :oops}

  def error_cast(_raw) do
    {:error, Core.Prim.wrap_error(__MODULE__, "внутренняя", :boom, "причина", :detail)}
  end

  describe "custom_validate" do
    defmodule EvenValidator do
      @moduledoc false

      @behaviour Core.Validator

      @impl true
      def validate(value, opts) do
        if rem(String.length(value), Keyword.fetch!(opts, :divisor)) == 0,
          do: :ok,
          else: {:error, {:not_even, "длина не кратна #{Keyword.fetch!(opts, :divisor)}"}}
      end
    end

    defmodule WithModuleValidator do
      @moduledoc "Значение с модульным валидатором"

      use Core.Prim.String,
        name: "Значение",
        max_len: 20,
        validate: {EvenValidator, divisor: 2}
    end

    defmodule WithArityTwoValidator do
      @moduledoc "Значение с валидатором fun/2"

      use Core.Prim.String,
        name: "Значение",
        max_len: 20,
        validate: &__MODULE__.check/2

      @doc false
      def check(value, opts) do
        if String.length(value) <= Keyword.fetch!(opts, :max_len),
          do: :ok,
          else: {:error, {:too_long, "слишком длинное"}}
      end
    end

    test "принимает {Module, opts}" do
      assert {:ok, _} = WithModuleValidator.new("abcd")
      assert {:error, %Core.Error{code: :not_even}} = WithModuleValidator.new("abc")
    end

    test "принимает fun/2 и передаёт type_opts" do
      assert {:ok, _} = WithArityTwoValidator.new("abc")
    end
  end
end
