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
    use Core.Prim.String,
      name: "Токен",
      sec_max_len: 8
  end

  defmodule Raw do
    use Core.Prim.String,
      name: "Сырое",
      max_len: 10,
      trim: false
  end

  defmodule Chained do
    use Core.Prim.String,
      name: "Цепочка",
      max_len: 10,
      mutate: [&String.upcase/1, &String.reverse/1]
  end

  defmodule Slug do
    use Core.Prim.String,
      name: "Слаг",
      max_len: 20,
      kind: :slug
  end

  defmodule Exact do
    use Core.Prim.String,
      name: "Код валюты",
      len: 3
  end

  defmodule One do
    use Core.Prim.String,
      name: "Один",
      len: 1
  end

  defmodule Five do
    use Core.Prim.String,
      name: "Пять",
      len: 5
  end

  defmodule MinOnly do
    use Core.Prim.String,
      name: "Минимум",
      min_len: 1,
      sec_max_len: 50
  end

  defmodule MaxOnly do
    use Core.Prim.String,
      name: "Максимум",
      max_len: 2
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
    assert {:error, %Core.Error{message: "Наименование: от 3 до 10 символов"}} =
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
              message: "Наименование: от 3 до 10 символов"
            }} = Name.new("Ab")
  end

  test "validates max_len" do
    assert {:error,
            %Core.Error{
              kind: :domain,
              message: "Наименование: от 3 до 10 символов"
            }} = Name.new("Abcdefghijk")
  end

  test "validates re" do
    assert {:error, %Core.Error{kind: :domain, message: "Наименование: неверный формат"}} =
             Name.new("Al1ce")
  end

  test "validates exact length" do
    assert {:ok, %Exact{value: "RUB"}} = Exact.new("RUB")

    assert {:error, %Core.Error{kind: :domain, code: :bounds, message: "Код валюты: ровно 3 символа"}} =
             Exact.new("RU")
  end

  test "склоняет сообщения о длине" do
    assert {:error, %Core.Error{message: "Один: ровно 1 символ"}} = One.new("")
    assert {:error, %Core.Error{message: "Пять: ровно 5 символов"}} = Five.new("abcd")
    assert {:error, %Core.Error{message: "Минимум: минимум 1 символ"}} = MinOnly.new("")
    assert {:error, %Core.Error{message: "Максимум: максимум 2 символа"}} = MaxOnly.new("abc")
  end

  test "склоняет 11 и 21" do
    eleven = compile_string(name: "Одиннадцать", len: 11)
    assert {:error, %Core.Error{message: "Одиннадцать: ровно 11 символов"}} = eleven.new("")

    twenty_one = compile_string(name: "Двадцать один", len: 21)
    assert {:error, %Core.Error{message: "Двадцать один: ровно 21 символ"}} = twenty_one.new("")
  end

  test "склоняет верхнюю границу диапазона" do
    range21 = compile_string(name: "До 21", min_len: 20, max_len: 21)

    assert {:error, %Core.Error{message: "До 21: от 20 до 21 символа"}} =
             range21.new(String.duplicate("a", 19))

    range11 = compile_string(name: "До 11", min_len: 5, max_len: 11)
    assert {:error, %Core.Error{message: "До 11: от 5 до 11 символов"}} = range11.new("abcd")
  end

  test "len задаёт байтовую границу" do
    assert Core.Prim.String.sec_max_len(Exact.__domain_type_opts__()) == 3 * 4 + 50

    value = String.duplicate("👨‍👩‍👧‍👦", 3)
    assert String.length(value) == 3
    assert byte_size(value) > 62
    assert {:error, %Core.Error{message: "Код валюты: невалидное значение"}} = Exact.new(value)
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

  test "__domain_type_opts__/0 раскрывает len" do
    opts = Exact.__domain_type_opts__()

    assert Enum.sort(Keyword.keys(opts)) == ~w(max_len min_len)a
    assert Keyword.fetch!(opts, :min_len) == 3
    assert Keyword.fetch!(opts, :max_len) == 3
  end

  test "требует max_len или sec_max_len at compile time" do
    assert_raise CompileError, ~r/нужен max_len, len или sec_max_len/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.NoLimit do
            use Core.Prim.String,
              name: "X",
              min_len: 1
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
            use Core.Prim.String,
              name: "X",
              min_len: 5,
              max_len: 3
          end
        end
      )
    end
  end

  test "rejects degenerate min_len == max_len at compile time" do
    assert_raise CompileError, ~r/min_len и max_len равны \(3\) — точную длину задаёт len: 3/, fn ->
      compile_string(name: "X", min_len: 3, max_len: 3)
    end
  end

  test "rejects zero exact length at compile time" do
    assert_raise CompileError, ~r/нулевая длина недопустима — len требует целое ≥ 1/, fn ->
      compile_string(name: "X", min_len: 0, max_len: 0)
    end

    assert_raise CompileError, ~r/len: ожидается целое ≥ 1, получено 0/, fn ->
      compile_string(name: "X", len: 0)
    end
  end

  test "rejects len together with min_len or max_len at compile time" do
    for own <- [[len: 3, min_len: 1], [len: 3, max_len: 5]] do
      assert_raise CompileError, ~r/len: не сочетается с (min_len|max_len)/, fn ->
        compile_string([name: "X"] ++ own)
      end
    end
  end

  test "rejects non-regex re at compile time" do
    assert_raise CompileError, ~r/re: ожидается %Regex\{\}/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Prim.StringTest.BadRe do
            use Core.Prim.String,
              name: "X",
              max_len: 5,
              re: "^a$"
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
            use Core.Prim.String,
              min_len: 1,
              max_len: 5
          end
        end
      )
    end
  end

  # ---

  defp compile_string(opts) do
    name = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    {{:module, mod, _bin, _}, _binding} =
      Code.eval_quoted(
        quote do
          defmodule unquote(name) do
            use Core.Prim.String, unquote(opts)
          end
        end
      )

    mod
  end
end
