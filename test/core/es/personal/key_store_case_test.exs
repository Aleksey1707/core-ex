defmodule Core.Es.Personal.KeyStoreCaseTest do
  use ExUnit.Case, async: true

  alias Core.Es.Personal.KeyStoreCase

  describe "опции" do
    test "нет impl: — CompileError" do
      assert_raise CompileError, ~r/^Es\.Personal\.KeyStoreCase: нет обязательных опций: \[:impl\]$/, fn ->
        use_case(async: true)
      end
    end

    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/^Es\.Personal\.KeyStoreCase: async: ожидается boolean, получено :yes$/, fn ->
        use_case(impl: Core.Version, async: :yes)
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Es\.Personal\.KeyStoreCase: неизвестные опции: \[:asnyc\]$/, fn ->
        {:ok, env} = Macro.Env.define_require(__ENV__, [], KeyStoreCase)
        Macro.expand(quote(do: Core.Es.Personal.KeyStoreCase.__using__(impl: Core.Version, asnyc: true)), env)
      end
    end

    test "атрибут в опции — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Es\.Personal\.KeyStoreCase: impl: ожидается литерал, получено @impl$/, fn ->
        use_case(impl: quote(do: @impl))
      end
    end
  end

  # ---

  defp use_case(opts) do
    Code.eval_quoted(
      quote do
        defmodule Core.Es.Personal.KeyStoreCaseTest.Case do
          use Core.Es.Personal.KeyStoreCase, unquote(opts)
        end
      end
    )
  end
end
