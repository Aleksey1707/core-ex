defmodule Core.Helper.StartOptsTest do
  use ExUnit.Case, async: true

  alias Core.Helper.StartOpts
  alias Core.Mq

  @label "Test.Process"

  test "module!: модуль, иначе ошибка с именем опции" do
    assert StartOpts.module!(@label, [connection: MyConn], :connection) == MyConn

    assert_raise ArgumentError, ~r/:connection — ожидается модуль, получено "MyConn"/, fn ->
      StartOpts.module!(@label, [connection: "MyConn"], :connection)
    end

    assert_raise ArgumentError, ~r/нет обязательной опции :connection/, fn ->
      StartOpts.module!(@label, [], :connection)
    end
  end

  test "atom!: nil модулем не считается" do
    assert StartOpts.atom!(@label, [dep: :klife], :dep) == :klife

    assert_raise ArgumentError, ~r/:dep — ожидается атом/, fn ->
      StartOpts.atom!(@label, [dep: nil], :dep)
    end
  end

  test "prim!: структура ожидаемого модуля" do
    topic = Mq.Topic.new!("products")

    assert StartOpts.prim!(@label, [topic: topic], :topic, Mq.Topic) == topic

    assert_raise ArgumentError, ~r/:topic — ожидается %Core.Mq.Topic\{\}/, fn ->
      StartOpts.prim!(@label, [topic: "products"], :topic, Mq.Topic)
    end

    assert_raise ArgumentError, ~r/:topic — ожидается %Core.Mq.Topic\{\}/, fn ->
      StartOpts.prim!(@label, [topic: Mq.Key.new!("agg-1")], :topic, Mq.Topic)
    end
  end

  test "binary!: непустая строка" do
    assert StartOpts.binary!(@label, [prefix: "writer"], :prefix) == "writer"

    assert_raise ArgumentError, ~r/:prefix — ожидается непустую строку/, fn ->
      StartOpts.binary!(@label, [prefix: ""], :prefix)
    end
  end

  test "pos_integer!: default при отсутствии, ноль и не-число — ошибка" do
    assert StartOpts.pos_integer!(@label, [], :credit, 2) == 2
    assert StartOpts.pos_integer!(@label, [credit: 5], :credit, 2) == 5

    assert_raise ArgumentError, ~r/:credit — ожидается положительное целое, получено 0/, fn ->
      StartOpts.pos_integer!(@label, [credit: 0], :credit, 2)
    end

    assert_raise ArgumentError, fn ->
      StartOpts.pos_integer!(@label, [credit: "5"], :credit, 2)
    end
  end

  test "boolean!: default при отсутствии" do
    assert StartOpts.boolean!(@label, [], :reliable?, true)
    refute StartOpts.boolean!(@label, [reliable?: false], :reliable?, true)

    assert_raise ArgumentError, ~r/:reliable\? — ожидается true или false/, fn ->
      StartOpts.boolean!(@label, [reliable?: :yes], :reliable?, true)
    end
  end

  test "one_of!: значение из множества" do
    assert StartOpts.one_of!(@label, [mode: :last], :mode, ~w(first last)a, :first) == :last
    assert StartOpts.one_of!(@label, [], :mode, ~w(first last)a, :first) == :first

    assert_raise ArgumentError, ~r/:mode — ожидается одно из \[:first, :last\]/, fn ->
      StartOpts.one_of!(@label, [mode: :middle], :mode, ~w(first last)a, :first)
    end
  end

  test "raise_invalid!: своё описание ожидаемого" do
    assert_raise ArgumentError, ~r/:offset — ожидается \{:offset, n\}, получено :bogus/, fn ->
      StartOpts.raise_invalid!(@label, :offset, "{:offset, n}", :bogus)
    end
  end
end
