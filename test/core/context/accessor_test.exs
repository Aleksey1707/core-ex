defmodule Core.Context.AccessorTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Error
  alias Core.Exc
  alias Core.PrimFixture

  defmodule CurrentActor do
    use Core.Context.Accessor, key: :current_actor
  end

  defmodule CurrentName do
    use Core.Context.Accessor,
      key: :current_name,
      type: Core.PrimFixture.Plain
  end

  defmodule Shouted do
    use Core.Context.Accessor, key: :shouted

    def put(%Context{} = context, value) when is_binary(value),
      do: super(context, String.upcase(value))
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

  test "type: сужает значение до своего Prim" do
    name = PrimFixture.Plain.new!("Иван")
    ctx = CurrentName.put(Context.new(), name)

    assert CurrentName.find(ctx) == name
    assert {:ok, ^name} = CurrentName.get(ctx)
    assert CurrentName.get!(ctx) == name
  end

  test "сохранённый nil отличим от отсутствующего ключа" do
    ctx = CurrentActor.put(Context.new(), nil)

    assert CurrentActor.exists?(ctx)
    assert CurrentActor.find(ctx) == nil
    assert CurrentActor.get(ctx) == {:ok, nil}
  end

  test "разные accessor'ы не делят значение" do
    name = PrimFixture.Plain.new!("Иван")

    ctx =
      Context.new()
      |> CurrentActor.put("actor")
      |> CurrentName.put(name)

    assert CurrentActor.find(ctx) == "actor"
    assert CurrentName.find(ctx) == name

    ctx = CurrentActor.delete(ctx)

    refute CurrentActor.exists?(ctx)
    assert CurrentName.find(ctx) == name
  end

  test "генерируемые функции переопределяемы" do
    ctx = Shouted.put(Context.new(), "actor")

    assert Shouted.find(ctx) == "ACTOR"
  end

  test "rejects unknown options at compile time" do
    assert_raise CompileError, ~r/неизвестные опции: \[:foo\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Context.AccessorTest.Bad do
            use Core.Context.Accessor, key: :x, foo: 1
          end
        end
      )
    end
  end

  test "требует key:" do
    assert_raise CompileError, ~r/нет обязательных опций: \[:key\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Context.AccessorTest.NoKey do
            use Core.Context.Accessor
          end
        end
      )
    end
  end

  test "key: — только атом" do
    assert_raise CompileError, ~r/key: ожидается атом, получено "x"/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Context.AccessorTest.StringKey do
            use Core.Context.Accessor, key: "x"
          end
        end
      )
    end
  end

  test "type: — только модуль" do
    assert_raise CompileError, ~r/type: ожидается модуль, получено "x"/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Context.AccessorTest.StringType do
            use Core.Context.Accessor, key: :x, type: "x"
          end
        end
      )
    end
  end
end
