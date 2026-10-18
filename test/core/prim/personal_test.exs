defmodule Core.Prim.PersonalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Core.Error
  alias Core.PrimFixture

  # Фикстуры Prim — в `test/support`: Prim, объявленный в самом тесте, не попадает
  # в консолидированный Inspect, и `@derive` не сработает.
  @personal PrimFixture.Personal
  @plain PrimFixture.Plain
  @personal_ref PrimFixture.PersonalRef
  @personal_over_plain PrimFixture.PersonalOverPlain
  @both PrimFixture.PersonalSensitive

  @phone "+79991234567"

  describe "inspect персонального Prim" do
    test "не показывает значение" do
      {:ok, prim} = @personal.new(@phone)

      refute inspect(prim) =~ @phone
      assert inspect(prim) =~ "Personal<"
    end

    test "композит над персональной базой не показывает значение" do
      {:ok, prim} = @personal_ref.new(@phone)

      refute inspect(prim) =~ @phone
    end

    test "Prim с обоими флагами не показывает значение" do
      {:ok, prim} = @both.new(@phone)

      refute inspect(prim) =~ @phone
    end

    test "value/1 по-прежнему отдаёт значение" do
      {:ok, prim} = @personal.new(@phone)

      assert @personal.value(prim) == @phone
    end
  end

  describe "Error.detail персонального Prim" do
    test "не содержит plaintext, только длину" do
      {:error, %Error{} = error} = @personal.new("short")

      assert error.detail == {:redacted, 5}
      refute inspect(error) =~ "short"
    end

    test "не-binary raw схлопывается в :redacted" do
      {:error, %Error{} = error} = @personal.new(12_345)

      assert error.detail == :redacted
    end

    test "plaintext не утекает через parent обычной базы" do
      {:error, %Error{} = error} = @personal_over_plain.new("ab")

      assert error.detail == {:redacted, 2}
      assert %Error{detail: {:redacted, 2}} = error.parent
      refute inspect(error) =~ "\"ab\""

      assert Enum.all?(Error.chain(error), &(&1.detail in [{:redacted, 2}, :redacted]))
    end
  end

  describe "__domain_personal__/0" do
    test "объявлен и различает персональные Prim" do
      assert @personal.__domain_personal__()
      refute @plain.__domain_personal__()
    end

    test "флаги независимы" do
      refute @personal.__domain_sensitive__()
      assert @both.__domain_personal__()
      assert @both.__domain_sensitive__()
    end

    test "Compose наследует признак базового Prim" do
      assert @personal_ref.__domain_personal__()
      refute @personal_ref.__domain_sensitive__()
    end

    test "Compose не даёт понизить признак базы" do
      assert_raise CompileError, ~r/personal: false поверх персонального/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Prim.PersonalTest.Downgraded do
              use Core.Prim.Compose,
                name: "Понижение",
                of: Core.PrimFixture.Personal,
                personal: false
            end
          end
        )
      end
    end

    test "personal: false поверх обычной базы допустим" do
      defmodule PlainRef do
        use Core.Prim.Compose,
          name: "Обычная ссылка",
          of: Core.PrimFixture.Plain,
          personal: false
      end

      refute PlainRef.__domain_personal__()
    end

    test "не-boolean значение — CompileError" do
      assert_raise CompileError, ~r/personal: ожидается true или false/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Prim.PersonalTest.BadPersonal do
              use Core.Prim.String, name: "X", max_len: 10, personal: :yes
            end
          end
        )
      end
    end

    test "опция есть у всех обёрток, по умолчанию false" do
      for {wrapper, opts} <- [
            {Core.Prim.String, [max_len: 10]},
            {Core.Prim.Integer, []},
            {Core.Prim.Decimal, []},
            {Core.Prim.UUID, [version: 4]},
            {Core.Prim.DateTime, []},
            {Core.Prim.Date, []},
            {Core.Prim.Compose, [of: Core.PrimFixture.Plain]}
          ] do
        name = Module.concat(__MODULE__, "Wrapped#{System.unique_integer([:positive])}")
        default = Module.concat(name, Default)

        # `@derive Inspect` модуля, объявленного после консолидации, не действует — предупреждение
        # о нём к проверке опции не относится.
        capture_io(:stderr, fn ->
          Code.eval_quoted(
            quote do
              defmodule unquote(name) do
                use unquote(wrapper), unquote([name: "X", personal: true] ++ opts)
              end

              defmodule unquote(default) do
                use unquote(wrapper), unquote([name: "X"] ++ opts)
              end
            end
          )
        end)

        assert name.__domain_personal__(), "#{inspect(wrapper)}: personal: true"
        refute default.__domain_personal__(), "#{inspect(wrapper)}: по умолчанию"
      end
    end
  end
end
