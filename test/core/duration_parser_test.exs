defmodule Core.DurationParserTest do
  use ExUnit.Case, async: true

  alias Core.DurationParser
  alias Core.Error
  alias Core.Exc

  describe "parse/1 (единица по умолчанию — секунды)" do
    test "одиночные единицы" do
      assert DurationParser.parse("20s") == {:ok, 20}
      assert DurationParser.parse("2d") == {:ok, 172_800}
      assert DurationParser.parse("5m") == {:ok, 300}
    end

    test "составные строки суммируются" do
      assert DurationParser.parse("5m20s") == {:ok, 320}
      assert DurationParser.parse("1h30m5s") == {:ok, 5405}
    end

    test "дробные значения, кратные секунде" do
      assert DurationParser.parse("2.5h") == {:ok, 9000}
      assert DurationParser.parse("0.5m") == {:ok, 30}
    end

    test "регистр строки не важен" do
      assert DurationParser.parse("1H30M") == DurationParser.parse("1h30m")
    end

    test "пробелы вокруг и между токенами допустимы" do
      assert DurationParser.parse(" 1h 30m 5s ") == {:ok, 5405}
      assert DurationParser.parse("5 m") == {:ok, 300}
    end
  end

  describe "parse/2 (явная единица результата)" do
    test "конвертация в разные единицы" do
      assert DurationParser.parse("1h30m5s", :ms) == {:ok, 5_405_000}
      assert DurationParser.parse("2d", :h) == {:ok, 48}
      assert DurationParser.parse("1500ms", :ms) == {:ok, 1500}
      assert DurationParser.parse("3600s", :h) == {:ok, 1}
      assert DurationParser.parse("7d", :s) == {:ok, 604_800}
      assert DurationParser.parse("1s", :us) == {:ok, 1_000_000}
      assert DurationParser.parse("1s", :ns) == {:ok, 1_000_000_000}
    end

    test ":s эквивалентен parse/1" do
      assert DurationParser.parse("10s", :s) == DurationParser.parse("10s")
    end

    test ~s|"ms" не путается с "m" (регрессия)| do
      assert DurationParser.parse("30ms", :ms) == {:ok, 30}
      assert DurationParser.parse("30m", :ms) == {:ok, 1_800_000}
      refute DurationParser.parse("30ms", :ms) == DurationParser.parse("30m", :ms)
    end

    test "результат — integer, не float" do
      assert {:ok, value} = DurationParser.parse("20s")
      assert is_integer(value)
    end

    test "дробные токены точны в мелкой единице" do
      assert DurationParser.parse("1.5s", :ms) == {:ok, 1500}
      assert DurationParser.parse("0.1s", :ms) == {:ok, 100}
      assert DurationParser.parse("0.000001s", :us) == {:ok, 1}
      assert DurationParser.parse("100ns", :ns) == {:ok, 100}
    end

    test "округление применяется к сумме, а не к отдельным токенам" do
      assert DurationParser.parse("0.5s 0.5s", :s) == {:ok, 1}
      assert DurationParser.parse("0.5ms 0.5ms", :ms) == {:ok, 1}
    end
  end

  describe "parse/3 (rounding)" do
    test ":no (по умолчанию) — неточная конвертация даёт ошибку" do
      assert {:error, %Error{kind: :domain, ns: :duration_parser, code: :precision_loss}} =
               DurationParser.parse("1500ms", :s)

      assert DurationParser.parse("1500ms", :s) ==
               DurationParser.parse("1500ms", :s, rounding: :no)
    end

    test ":trunc / :ceil / :round" do
      assert DurationParser.parse("1500ms", :s, rounding: :trunc) == {:ok, 1}
      assert DurationParser.parse("1500ms", :s, rounding: :ceil) == {:ok, 2}
      assert DurationParser.parse("1500ms", :s, rounding: :round) == {:ok, 2}

      assert DurationParser.parse("500us", :ms, rounding: :trunc) == {:ok, 0}
      assert DurationParser.parse("500us", :ms, rounding: :ceil) == {:ok, 1}
      assert DurationParser.parse("500us", :ms, rounding: :round) == {:ok, 1}

      assert DurationParser.parse("1400ms", :s, rounding: :round) == {:ok, 1}
    end

    test "неизвестный ключ opts — ошибка программиста" do
      assert_raise ArgumentError, fn -> DurationParser.parse("1s", :s, timeout: 1) end
    end

    test "неизвестная политика округления — ошибка программиста" do
      assert_raise FunctionClauseError, fn -> DurationParser.parse("1s", :s, rounding: :floor) end
    end
  end

  describe "невалидный формат строки" do
    test "пустая или пробельная строка" do
      assert {:error, %Error{kind: :domain, ns: :duration_parser, code: :invalid_format}} =
               DurationParser.parse("")

      assert {:error, %Error{kind: :domain, ns: :duration_parser, code: :invalid_format}} =
               DurationParser.parse("   ")
    end

    test "строка без распознаваемых единиц" do
      assert {:error, %Error{kind: :domain, ns: :duration_parser, code: :invalid_format}} =
               DurationParser.parse("abc")
    end

    test "голое число без единицы не принимается" do
      assert {:error, %Error{code: :invalid_format}} = DurationParser.parse("1000", :ms)
      assert {:error, %Error{code: :invalid_format}} = DurationParser.to_timeout("1000")
    end

    test "мусор после валидного токена" do
      assert {:error, %Error{code: :invalid_format}} = DurationParser.parse("5m tomorrow")
    end

    test "мусор перед валидным токеном" do
      assert {:error, %Error{code: :invalid_format}} = DurationParser.parse("abc5m")
    end
  end

  describe "parse!/1,2,3" do
    test "happy path зеркалит parse/1,2,3" do
      assert DurationParser.parse!("1h30m5s") == 5405
      assert DurationParser.parse!("1h30m5s", :ms) == 5_405_000
      assert DurationParser.parse!("1500ms", :s, rounding: :ceil) == 2
    end

    test "невалидный формат → Exc" do
      assert_raise Exc, fn -> DurationParser.parse!("abc") end
    end

    test "неточная конвертация → Exc" do
      assert_raise Exc, fn -> DurationParser.parse!("1500ms", :s) end
    end
  end

  describe "to_duration/1,2" do
    test "составная строка нормализуется в day/hour/minute/second/microsecond" do
      assert DurationParser.to_duration("1h30m5s") ==
               {:ok, Duration.new!(hour: 1, minute: 30, second: 5)}
    end

    test "дробные значения дают microsecond" do
      assert DurationParser.to_duration("1.5s") ==
               {:ok, Duration.new!(second: 1, microsecond: {500_000, 6})}

      assert DurationParser.to_duration("30ms") ==
               {:ok, Duration.new!(microsecond: {30_000, 6})}
    end

    test "перенос через границы единиц" do
      assert DurationParser.to_duration("90m") == {:ok, Duration.new!(hour: 1, minute: 30)}
      assert DurationParser.to_duration("25h") == {:ok, Duration.new!(day: 1, hour: 1)}
    end

    test "нулевая длительность" do
      assert DurationParser.to_duration("0s") == {:ok, Duration.new!(second: 0)}
    end

    test "точность Duration — микросекунда" do
      assert {:error, %Error{code: :precision_loss}} = DurationParser.to_duration("100ns")

      assert DurationParser.to_duration("100ns", rounding: :trunc) ==
               {:ok, Duration.new!(second: 0)}
    end

    test "невалидный формат" do
      assert {:error, %Error{code: :invalid_format}} = DurationParser.to_duration("abc")
    end
  end

  describe "to_duration!/1,2" do
    test "happy path зеркалит to_duration/1,2" do
      assert DurationParser.to_duration!("1h30m5s") ==
               Duration.new!(hour: 1, minute: 30, second: 5)
    end

    test "невалидный формат → Exc" do
      assert_raise Exc, fn -> DurationParser.to_duration!("abc") end
    end
  end

  describe "to_timeout/1,2" do
    test "строка длительности → целые миллисекунды" do
      assert DurationParser.to_timeout("30s") == {:ok, 30_000}
      assert DurationParser.to_timeout("1h30m5s") == {:ok, 5_405_000}
    end

    test "суб-миллисекундный остаток по умолчанию — ошибка" do
      assert {:error, %Error{code: :precision_loss}} = DurationParser.to_timeout("500us")
      assert DurationParser.to_timeout("500us", rounding: :trunc) == {:ok, 0}
    end

    test "целое число трактуется как миллисекунды (как Kernel.to_timeout/1)" do
      assert DurationParser.to_timeout(1000) == {:ok, 1000}
      assert DurationParser.to_timeout(0) == {:ok, 0}
    end

    test ":infinity проходит насквозь" do
      assert DurationParser.to_timeout(:infinity) == {:ok, :infinity}
    end

    test "Duration.t()" do
      assert DurationParser.to_timeout(Duration.new!(hour: 1, minute: 30)) == {:ok, 5_400_000}
      assert DurationParser.to_timeout(Duration.new!(week: 1)) == {:ok, 604_800_000}

      assert {:error, %Error{code: :precision_loss}} =
               DurationParser.to_timeout(Duration.new!(microsecond: {500, 6}))

      assert DurationParser.to_timeout(Duration.new!(microsecond: {500, 6}), rounding: :ceil) ==
               {:ok, 1}
    end

    test "keyword-компоненты" do
      assert DurationParser.to_timeout(hour: 1, minute: 30) == {:ok, 5_400_000}
      assert DurationParser.to_timeout(millisecond: 5) == {:ok, 5}
      assert DurationParser.to_timeout(nanosecond: 1_000_000) == {:ok, 1}
    end

    test "повторяющиеся компоненты keyword суммируются" do
      assert DurationParser.to_timeout(second: 1, second: 2) == {:ok, 3000}
    end

    test "year / month в Duration не конвертируются" do
      assert {:error, %Error{code: :unsupported_component}} =
               DurationParser.to_timeout(Duration.new!(month: 1))

      assert {:error, %Error{code: :unsupported_component}} =
               DurationParser.to_timeout(Duration.new!(year: 1))
    end

    test "отрицательная длительность" do
      assert {:error, %Error{code: :negative_duration}} =
               DurationParser.to_timeout(Duration.new!(second: -5))

      assert {:error, %Error{code: :negative_duration}} = DurationParser.to_timeout(second: -5)
    end

    test "неизвестный компонент keyword" do
      assert {:error, %Error{code: :invalid_component}} = DurationParser.to_timeout(fortnight: 1)
    end

    test "невалидный формат" do
      assert {:error, %Error{kind: :domain, ns: :duration_parser, code: :invalid_format}} =
               DurationParser.to_timeout("abc")
    end
  end

  describe "to_timeout!/1,2" do
    test "happy path зеркалит to_timeout/1,2" do
      assert DurationParser.to_timeout!("30s") == 30_000
      assert DurationParser.to_timeout!(:infinity) == :infinity
      assert DurationParser.to_timeout!("500us", rounding: :ceil) == 1
    end

    test "невалидный формат → Exc" do
      assert_raise Exc, fn -> DurationParser.to_timeout!("abc") end
    end
  end

  describe "enum'ы модуля" do
    test "закрытое множество единиц" do
      assert DurationParser.Unit.values() == ~w(d h m s ms us ns)a
    end

    test "закрытое множество политик округления" do
      assert DurationParser.Rounding.values() == ~w(no trunc ceil round)a
    end
  end

  describe "to_timeout/2: недопустимый ввод" do
    test "отрицательное целое" do
      assert {:error, %Error{code: :negative_duration}} = DurationParser.to_timeout(-1)
    end

    test "float" do
      assert {:error, %Error{code: :invalid_input}} = DurationParser.to_timeout(1.5)
    end

    test "charlist" do
      assert {:error, %Error{code: :invalid_input}} = DurationParser.to_timeout(~c"5s")
    end
  end
end
