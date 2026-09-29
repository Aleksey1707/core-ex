defmodule Core.Web.PreferTest do
  use ExUnit.Case, async: true

  alias Core.Web.Prefer

  @max 5_000

  describe "parse" do
    test "без заголовка — пустые предпочтения" do
      assert Prefer.parse([]) == %Prefer{respond_async: false, wait: nil}
    end

    test "respond-async и wait из одного и из нескольких заголовков" do
      assert Prefer.parse(["respond-async, wait=3"]) == %Prefer{respond_async: true, wait: 3}
      assert Prefer.parse(["respond-async", "wait=3"]) == %Prefer{respond_async: true, wait: 3}
    end

    test "токен без учёта регистра, пробелы вокруг = и параметры после ; игнорируются" do
      assert Prefer.parse(["Respond-Async; foo=bar , WAIT = 7"]) == %Prefer{respond_async: true, wait: 7}
    end

    test "значение wait в кавычках" do
      assert Prefer.parse([~s(wait="4")]) == %Prefer{respond_async: false, wait: 4}
    end

    test "повтор предпочтения — учитывается первое" do
      assert Prefer.parse(["wait=2, wait=9"]) == %Prefer{respond_async: false, wait: 2}
      assert Prefer.parse(["wait=2", "wait=9"]) == %Prefer{respond_async: false, wait: 2}
    end

    test "неизвестный токен и неразборчивый wait игнорируются" do
      for value <- ["return=minimal", "wait=soon", "wait=-1", "wait=+5", "wait=", "wait", ~s(wait="5), ~s(wait="4\n")] do
        assert Prefer.parse([value]) == %Prefer{respond_async: false, wait: nil}, value
      end
    end

    test "неразборчивый первый wait не уступает место следующему" do
      assert Prefer.parse(["wait=x, wait=5"]) == %Prefer{respond_async: false, wait: nil}
    end

    test "запятая и экранированная кавычка внутри кавычек не делят заголовок" do
      assert Prefer.parse([~s(foo="a, respond-async", wait=1)]) == %Prefer{respond_async: false, wait: 1}
      assert Prefer.parse([~s(foo="a\\", respond-async", wait=1)]) == %Prefer{respond_async: false, wait: 1}
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

    test "предел не кратен секунде — применённое округляется вверх" do
      prefer = Prefer.parse(["wait=60"])

      assert Prefer.mode(prefer, 50) == {:wait, 50}
      assert Prefer.applied(prefer, 50, 200) == "wait=1"
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
