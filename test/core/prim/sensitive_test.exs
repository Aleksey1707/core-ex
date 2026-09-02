defmodule Core.Prim.SensitiveTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.PrimFixture
  alias Core.PrimFixture.Password
  alias Core.PrimFixture.Session

  # Фикстуры Prim — в `test/support`: Prim, объявленный в самом тесте, не попадает
  # в консолидированный Inspect, и `@derive` не сработает.
  @secretish PrimFixture.Sensitive
  @plain PrimFixture.Plain
  @secretish_ref PrimFixture.SensitiveRef
  @secretish_over_plain PrimFixture.SensitiveOverPlain

  @plaintext "sup3r-secret-value"

  describe "inspect чувствительного Prim" do
    test "не показывает значение пароля" do
      {:ok, prim} = Password.new(@plaintext)

      refute inspect(prim) =~ @plaintext
      assert inspect(prim) =~ "Password<"
    end

    test "не показывает значение идентификатора сессии" do
      session_id = "01a03856-1b71-7d7d-8d1b-58c3ce01d110"
      {:ok, prim} = Session.ID.new(session_id)

      refute inspect(prim) =~ session_id
      assert inspect(prim) =~ "ID<"
    end

    test "value/1 по-прежнему отдаёт значение" do
      {:ok, prim} = Password.new(@plaintext)

      assert Password.value(prim) == @plaintext
    end
  end

  describe "Error.detail чувствительного Prim" do
    test "не содержит plaintext, только длину" do
      {:error, %Error{} = error} = @secretish.new("short")

      assert error.detail == {:redacted, 5}
      refute inspect(error) =~ "short"
    end

    test "не-binary raw схлопывается в :redacted" do
      {:error, %Error{} = error} = @secretish.new(12_345)

      assert error.detail == :redacted
    end

    test "реальный Prim пароля не пропускает plaintext в цепочку ошибки" do
      too_long = String.duplicate("s", 257)

      {:error, %Error{} = error} = Password.new(too_long)

      refute inspect(error) =~ too_long
      assert error.detail == {:redacted, 257}
    end
  end

  describe "cause-цепочка чувствительного Prim" do
    test "plaintext не утекает через parent несенситивной базы" do
      {:error, %Error{} = error} = @secretish_over_plain.new("ab")

      assert error.detail == {:redacted, 2}
      assert %Error{detail: {:redacted, 2}} = error.parent
      refute inspect(error) =~ "\"ab\""

      assert Enum.all?(Error.chain(error), &(&1.detail in [{:redacted, 2}, :redacted]))
    end
  end

  describe "__domain_sensitive__/0" do
    test "объявлен и различает чувствительные Prim" do
      assert @secretish.__domain_sensitive__()
      refute @plain.__domain_sensitive__()
    end

    test "Compose наследует чувствительность базового Prim" do
      assert @secretish_ref.__domain_sensitive__()
    end
  end

  describe "несенситивный Prim" do
    test "inspect и detail не меняются" do
      {:error, %Error{} = error} = @plain.new("ab")

      assert error.detail == "ab"
    end
  end
end
