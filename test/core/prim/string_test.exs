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

  defmodule SecOnly do
    use Core.Prim.String, name: "Токен", sec_max_len: 8
  end

  defmodule Raw do
    use Core.Prim.String, name: "Сырое", max_len: 10, trim: false
  end

  defmodule Chained do
    use Core.Prim.String,
      name: "Цепочка",
      max_len: 10,
      mutate: [&String.upcase/1, &String.reverse/1]
  end

  defmodule Slug do
    use Core.Prim.String, name: "Слаг", max_len: 20, kind: :slug
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

  test "явный sec_max_len работает без max_len" do
    assert {:ok, %SecOnly{value: "abcdefgh"}} = SecOnly.new("abcdefgh")

    assert {:error, %Core.Error{message: "Токен: невалидное значение"}} =
             SecOnly.new("abcdefghi")
  end

  test "trim: false сохраняет пробелы" do
    assert {:ok, %Raw{value: "  a  "}} = Raw.new("  a  ")
  end

  test "mutate списком применяется по порядку" do
    assert {:ok, %Chained{value: "BA"}} = Chained.new("ab")
  end

  test "__domain_type_opts__/0 отдаёт только опции типа" do
    opts = Name.__domain_type_opts__()

    assert Enum.sort(Keyword.keys(opts)) == ~w(max_len min_len re)a
    assert Keyword.fetch!(opts, :min_len) == 3
    assert Keyword.fetch!(opts, :max_len) == 10
    assert Keyword.fetch!(opts, :re).source == "^[A-Za-z]+$"
  end

  test "custom kind сохраняется" do
    assert Slug.__domain_kind__() == :slug
    assert {:ok, %Slug{value: "abc"}} = Slug.new("abc")
  end

  test "требует max_len или sec_max_len at compile time" do
    assert_raise CompileError, ~r/нужен max_len или sec_max_len/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.NoLimit do
            use Core.Prim.String, name: "X", min_len: 1
          end
        end
      )
    end
  end

  test "rejects min_len > max_len at compile time" do
    assert_raise CompileError, ~r/min_len \(5\) больше max_len \(3\)/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.BadBounds do
            use Core.Prim.String, name: "X", min_len: 5, max_len: 3
          end
        end
      )
    end
  end

  test "rejects non-regex re at compile time" do
    assert_raise CompileError, ~r/re: ожидается %Regex\{\}/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.BadRe do
            use Core.Prim.String, name: "X", max_len: 5, re: "^a$"
          end
        end
      )
    end
  end

  test "requires name at compile time" do
    assert_raise CompileError, ~r/нет обязательных опций: \[:name\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.NoName do
            use Core.Prim.String, min_len: 1, max_len: 5
          end
        end
      )
    end
  end
end
