defmodule Core.Web.PreferTest do
  use ExUnit.Case, async: true

  alias Core.Web.Prefer

  @max 5_000

  describe "parse" do
    test "без заголовка — пустые предпочтения" do
      assert Prefer.parse([]) == %Prefer{respond_async: false, wait_ms: nil}
    end

    test "respond-async и wait из одного и из нескольких заголовков" do
      assert Prefer.parse(["respond-async, wait=3"]) == %Prefer{respond_async: true, wait_ms: 3_000}
      assert Prefer.parse(["respond-async", "wait=3"]) == %Prefer{respond_async: true, wait_ms: 3_000}
    end

    test "токен без учёта регистра, пробелы вокруг = и параметры после ; игнорируются" do
      assert Prefer.parse(["Respond-Async; foo=bar , WAIT = 7"]) == %Prefer{respond_async: true, wait_ms: 7_000}
    end

    test "значение wait в кавычках" do
      assert Prefer.parse([~s(wait="4")]) == %Prefer{respond_async: false, wait_ms: 4_000}
    end

    test "повтор предпочтения — учитывается первое" do
      assert Prefer.parse(["wait=2, wait=9"]) == %Prefer{respond_async: false, wait_ms: 2_000}
      assert Prefer.parse(["wait=2", "wait=9"]) == %Prefer{respond_async: false, wait_ms: 2_000}
    end

    test "неизвестный токен и неразборчивый wait игнорируются" do
      for value <- ~w(return=minimal wait=soon wait=-1 wait=+5 wait= wait) ++ [~s(wait="5), ~s(wait="4\n")] do
        assert Prefer.parse([value]) == %Prefer{respond_async: false, wait_ms: nil}, value
      end
    end

    test "wait с дробной частью — в миллисекундах" do
      assert Prefer.parse(["wait=0.2"]) == %Prefer{respond_async: false, wait_ms: 200}
      assert Prefer.parse(["wait=1.5"]) == %Prefer{respond_async: false, wait_ms: 1_500}
      assert Prefer.parse([~s(wait="0.25")]) == %Prefer{respond_async: false, wait_ms: 250}
      assert Prefer.parse(["wait=0.2000"]) == %Prefer{respond_async: false, wait_ms: 200}
    end

    test "разряды дальше миллисекунды округляются вверх, ноль остаётся нулём" do
      assert Prefer.parse(["wait=0.0004"]) == %Prefer{respond_async: false, wait_ms: 1}
      assert Prefer.parse(["wait=0.2005"]) == %Prefer{respond_async: false, wait_ms: 201}
      assert Prefer.parse(["wait=0.9999"]) == %Prefer{respond_async: false, wait_ms: 1_000}
      assert Prefer.parse(["wait=0.0"]) == %Prefer{respond_async: false, wait_ms: 0}
      assert Prefer.parse(["wait=0.00000"]) == %Prefer{respond_async: false, wait_ms: 0}
    end

    test "десятичная запятая без кавычек делит заголовок — это wait=0 и токен" do
      assert Prefer.parse(["wait=0,2"]) == %Prefer{respond_async: false, wait_ms: 0}
    end

    test "неразборчивая дробь игнорируется" do
      for value <- ~w(wait=.2 wait=2. wait=1e-1 wait=+0.2 wait=-0.2 wait=0.2.1) ++ [~s(wait="0,2")] do
        assert Prefer.parse([value]) == %Prefer{respond_async: false, wait_ms: nil}, value
      end
    end

    test "неразборчивый первый wait не уступает место следующему" do
      assert Prefer.parse(["wait=x, wait=5"]) == %Prefer{respond_async: false, wait_ms: nil}
    end

    test "запятая и экранированная кавычка внутри кавычек не делят заголовок" do
      assert Prefer.parse([~s(foo="a, respond-async", wait=1)]) == %Prefer{respond_async: false, wait_ms: 1_000}
      assert Prefer.parse([~s(foo="a\\", respond-async", wait=1)]) == %Prefer{respond_async: false, wait_ms: 1_000}
    end
  end

  describe "mode и applied" do
    test "без предпочтений — ожидание с серверным пределом, без Preference-Applied" do
      prefer = Prefer.parse([])

      assert Prefer.mode(prefer, @max) == {:wait, @max}
      assert Prefer.applied(prefer, @max, 200) == nil
      assert Prefer.applied(prefer, @max, 202) == nil
    end

    test "respond-async — без ожидания" do
      prefer = Prefer.parse(["respond-async"])

      assert Prefer.mode(prefer, @max) == :respond_async
      assert Prefer.applied(prefer, @max, 202) == "respond-async"
    end

    test "wait=N в пределе — ожидание N секунд" do
      prefer = Prefer.parse(["wait=2"])

      assert Prefer.mode(prefer, @max) == {:wait, 2_000}
      assert Prefer.applied(prefer, @max, 200) == "wait=2"
      assert Prefer.applied(prefer, @max, 202) == "wait=2"
    end

    test "wait=N выше предела урезается до предела" do
      prefer = Prefer.parse(["wait=60"])

      assert Prefer.mode(prefer, @max) == {:wait, @max}
      assert Prefer.applied(prefer, @max, 202) == "wait=5"
    end

    test "предел не кратен секунде — применённое с дробной частью" do
      prefer = Prefer.parse(["wait=60"])

      assert Prefer.mode(prefer, 50) == {:wait, 50}
      assert Prefer.applied(prefer, 50, 200) == "wait=0.05"
      assert Prefer.applied(prefer, 1_250, 200) == "wait=1.25"
    end

    test "дробный wait в пределе — ожидание в миллисекундах" do
      prefer = Prefer.parse(["wait=0.2"])

      assert Prefer.mode(prefer, @max) == {:wait, 200}
      assert Prefer.applied(prefer, @max, 200) == "wait=0.2"
      assert Prefer.applied(prefer, @max, 202) == "wait=0.2"
    end

    test "дробный wait выше предела урезается до предела" do
      prefer = Prefer.parse(["wait=1.5"])

      assert Prefer.mode(prefer, 1_000) == {:wait, 1_000}
      assert Prefer.applied(prefer, 1_000, 202) == "wait=1"
    end

    test "разряды дальше миллисекунды — ожидание не меньше 1 мс" do
      prefer = Prefer.parse(["wait=0.0004"])

      assert Prefer.mode(prefer, @max) == {:wait, 1}
      assert Prefer.applied(prefer, @max, 200) == "wait=0.001"
    end

    test "respond-async вместе с wait=N — ожидание N; respond-async применён только на 202" do
      prefer = Prefer.parse(["respond-async, wait=2"])

      assert Prefer.mode(prefer, @max) == {:wait, 2_000}
      assert Prefer.applied(prefer, @max, 200) == "wait=2"
      assert Prefer.applied(prefer, @max, 202) == "respond-async, wait=2"
    end

    test "wait=0 — без ожидания" do
      prefer = Prefer.parse(["wait=0"])

      assert Prefer.mode(prefer, @max) == :respond_async
      assert Prefer.applied(prefer, @max, 202) == "wait=0"
    end

    test "wait=0.0 — без ожидания, применён как wait=0" do
      prefer = Prefer.parse(["wait=0.0"])

      assert Prefer.mode(prefer, @max) == :respond_async
      assert Prefer.applied(prefer, @max, 202) == "wait=0"
    end

    test "respond-async вместе с wait=0 — без ожидания, применены оба" do
      prefer = Prefer.parse(["respond-async, wait=0"])

      assert Prefer.mode(prefer, @max) == :respond_async
      assert Prefer.applied(prefer, @max, 202) == "respond-async, wait=0"
    end

    test "неизвестное предпочтение — как без заголовка" do
      prefer = Prefer.parse(["return=minimal"])

      assert Prefer.mode(prefer, @max) == {:wait, @max}
      assert Prefer.applied(prefer, @max, 202) == nil
    end
  end
end
