defmodule Core.Prim.StringTest do
  use ExUnit.Case, async: true

  defmodule Name do
    use Core.Prim.String,
      name: "Наименование",
      min_len: 3,
      max_len: 10,
      re: ~r/^[A-Za-z]+$/
  end

  defmodule WithHooks do
    use Core.Prim.String,
      name: "Код",
      min_len: 2,
      max_len: 10,
      mutate: &String.upcase/1,
      validate: &Core.Prim.StringTest.only_a/1
  end

  def only_a("AA"), do: :ok
  def only_a(_), do: {:error, {:only_a, "только AA"}}

  test "casts and trims binary" do
    assert {:ok, %Name{value: "Alice"}} = Name.new("  Alice  ")
  end

  test "rejects invalid cast as domain error" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Наименование: невалидное значение"
            }} = Name.new(123)
  end

  test "sec_max_len отсекает по байтам до посимвольных проверок" do
    # default = max_len (10) * 4 + 50 = 90 байт
    too_long = String.duplicate("a", 91)

    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Наименование: невалидное значение"
            }} = Name.new(too_long)

    # многобайтные символы укладываются в байтовую границу и доходят до max_len
    assert {:error, %Core.Error{message: "Наименование: от 3 до 10 символа(ов)"}} =
             Name.new(String.duplicate("я", 11))
  end

  test "невалидный UTF-8 отбраковывается на cast" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Наименование: невалидная UTF-8 строка"
            }} = Name.new(<<"ok", 0xFF, "tail">>)
  end

  test "validates min_len with russian message" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Наименование: от 3 до 10 символа(ов)"
            }} = Name.new("Ab")
  end

  test "validates max_len" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Наименование: от 3 до 10 символа(ов)"
            }} = Name.new("Abcdefghijk")
  end

  test "validates re" do
    assert {:error, %Core.Error{kind: :domain, message: "Наименование: неверный формат"}} =
             Name.new("Al1ce")
  end

  test "custom mutate and validate" do
    assert {:ok, %WithHooks{value: "AA"}} = WithHooks.new("aa")

    assert {:error,
            %Core.Error{
              kind: :domain,
              code: :only_a,
              message: "Код: только AA"
            }} = WithHooks.new("bb")
  end

  test "requires name at compile time" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:name\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.NoName do
            use Core.Prim.String, min_len: 1
          end
        end
      )
    end
  end
end
