defmodule Core.Context.AccessorTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Error
  alias Core.Exc

  defmodule CurrentActor do
    use Core.Context.Accessor, key: :current_actor
  end

  test "accessor wraps context key access" do
    ctx = Context.new() |> CurrentActor.put("actor")

    assert CurrentActor.exists?(ctx)
    assert CurrentActor.find(ctx) == "actor"
    assert {:ok, "actor"} = CurrentActor.get(ctx)
    assert CurrentActor.get!(ctx) == "actor"

    ctx = CurrentActor.delete(ctx)
    refute CurrentActor.exists?(ctx)
    assert {:error, %Error{code: :not_found}} = CurrentActor.get(ctx)

    assert_raise Exc, fn ->
      CurrentActor.get!(ctx)
    end
  end

  test "rejects unknown options at compile time" do
    assert_raise CompileError, ~r/unknown option\(s\): \[:foo\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Context.AccessorTest.Bad do
            use Core.Context.Accessor, key: :x, foo: 1
          end
        end
      )
    end
  end
end
