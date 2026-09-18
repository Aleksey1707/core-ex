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

  test "list!: обязательный список" do
    assert StartOpts.list!(@label, [items: [:a]], :items) == [:a]
    assert StartOpts.list!(@label, [items: []], :items) == []

    assert_raise ArgumentError, ~r/:items — ожидается список, получено :a/, fn ->
      StartOpts.list!(@label, [items: :a], :items)
    end

    assert_raise ArgumentError, ~r/нет обязательной опции :items/, fn ->
      StartOpts.list!(@label, [], :items)
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

  test "boolean!/3: обязательное булево" do
    assert StartOpts.boolean!(@label, [enabled: true], :enabled)
    refute StartOpts.boolean!(@label, [enabled: false], :enabled)

    assert_raise ArgumentError, ~r/:enabled — ожидается true или false, получено nil/, fn ->
      StartOpts.boolean!(@label, [enabled: nil], :enabled)
    end

    assert_raise ArgumentError, ~r/нет обязательной опции :enabled/, fn ->
      StartOpts.boolean!(@label, [], :enabled)
    end
  end

  test "one_of!: значение из множества" do
    assert StartOpts.one_of!(@label, [mode: :last], :mode, ~w(first last)a, :first) == :last
    assert StartOpts.one_of!(@label, [], :mode, ~w(first last)a, :first) == :first

    assert_raise ArgumentError, ~r/:mode — ожидается одно из \[:first, :last\]/, fn ->
      StartOpts.one_of!(@label, [mode: :middle], :mode, ~w(first last)a, :first)
    end
  end

  test "keys!: неизвестная опция — ошибка с её именем" do
    assert StartOpts.keys!(@label, [credit: 2, name: :reader], ~w(credit name)a) == :ok
    assert StartOpts.keys!(@label, [], ~w(credit)a) == :ok

    assert_raise ArgumentError, ~r/Test.Process: неизвестные опции \[:credti\], допустимые: \[:credit, :name\]/, fn ->
      StartOpts.keys!(@label, [credti: 2, name: :reader], ~w(credit name)a)
    end
  end

  test "pos_integer!/3: обязательное положительное целое" do
    assert StartOpts.pos_integer!(@label, [interval_ms: 5], :interval_ms) == 5

    assert_raise ArgumentError, ~r/:interval_ms — ожидается положительное целое, получено 0/, fn ->
      StartOpts.pos_integer!(@label, [interval_ms: 0], :interval_ms)
    end

    assert_raise ArgumentError, ~r/нет обязательной опции :interval_ms/, fn ->
      StartOpts.pos_integer!(@label, [], :interval_ms)
    end
  end

  test "term!: любое значение, кроме nil" do
    assert StartOpts.term!(@label, [reader: {:via, Registry, {:r, 1}}], :reader) == {:via, Registry, {:r, 1}}

    assert_raise ArgumentError, ~r/:reader — ожидается значение, получено nil/, fn ->
      StartOpts.term!(@label, [reader: nil], :reader)
    end

    assert_raise ArgumentError, ~r/нет обязательной опции :reader/, fn ->
      StartOpts.term!(@label, [], :reader)
    end
  end

  test "fun!/4: обязательная функция заданной арности" do
    decode = fn message -> {:ok, message} end

    assert StartOpts.fun!(@label, [from_message: decode], :from_message, 1) == decode

    assert_raise ArgumentError, ~r/:from_message — ожидается функция арности 1/, fn ->
      StartOpts.fun!(@label, [from_message: fn _m, _d -> :ok end], :from_message, 1)
    end

    assert_raise ArgumentError, ~r/:from_message — ожидается функция арности 1, получено :decode/, fn ->
      StartOpts.fun!(@label, [from_message: :decode], :from_message, 1)
    end

    assert_raise ArgumentError, ~r/нет обязательной опции :from_message/, fn ->
      StartOpts.fun!(@label, [], :from_message, 1)
    end
  end

  test "fun!/5: default при отсутствии" do
    factory = fn -> :context end

    assert StartOpts.fun!(@label, [], :context_factory, 0, factory) == factory
    assert StartOpts.fun!(@label, [context_factory: &Map.new/0], :context_factory, 0, factory) == (&Map.new/0)

    assert_raise ArgumentError, ~r/:context_factory — ожидается функция арности 0/, fn ->
      StartOpts.fun!(@label, [context_factory: &Map.new/1], :context_factory, 0, factory)
    end
  end

  test "module!/4: default при отсутствии, nil — допустимое значение" do
    assert StartOpts.module!(@label, [], :dlq_writer, nil) == nil
    assert StartOpts.module!(@label, [dlq_writer: nil], :dlq_writer, nil) == nil
    assert StartOpts.module!(@label, [dlq_writer: MyWriter], :dlq_writer, nil) == MyWriter

    assert_raise ArgumentError, ~r/:dlq_writer — ожидается модуль, получено "MyWriter"/, fn ->
      StartOpts.module!(@label, [dlq_writer: "MyWriter"], :dlq_writer, nil)
    end
  end

  test "binary!/4: default при отсутствии, пустая строка — ошибка" do
    assert StartOpts.binary!(@label, [], :topic, "unknown") == "unknown"
    assert StartOpts.binary!(@label, [topic: "products"], :topic, "unknown") == "products"

    assert_raise ArgumentError, ~r/:topic — ожидается непустую строку, получено ""/, fn ->
      StartOpts.binary!(@label, [topic: ""], :topic, "unknown")
    end

    assert_raise ArgumentError, ~r/:topic — ожидается непустую строку, получено nil/, fn ->
      StartOpts.binary!(@label, [topic: nil], :topic, "unknown")
    end
  end

  test "topics_filter!: :all, {:only, строки} или {:except, строки}" do
    assert StartOpts.topics_filter!(@label, [], :topics, :all) == :all
    assert StartOpts.topics_filter!(@label, [topics: {:only, ["orders"]}], :topics, :all) == {:only, ["orders"]}
    assert StartOpts.topics_filter!(@label, [topics: {:except, []}], :topics, :all) == {:except, []}

    for bad <- [["orders"], {:only, "orders"}, {:only, [:orders]}, {:all, ["orders"]}, nil] do
      assert_raise ArgumentError, ~r/:topics — ожидается :all, \{:only, \[String.t\(\)\]\} или/, fn ->
        StartOpts.topics_filter!(@label, [topics: bad], :topics, :all)
      end
    end
  end

  test "name!: необязательное имя процесса" do
    assert StartOpts.name!(@label, [], :name) == nil
    assert StartOpts.name!(@label, [name: nil], :name) == nil
    assert StartOpts.name!(@label, [name: :poller], :name) == :poller
    assert StartOpts.name!(@label, [name: {:global, :poller}], :name) == {:global, :poller}
    assert StartOpts.name!(@label, [name: {:via, Registry, {:r, 1}}], :name) == {:via, Registry, {:r, 1}}

    for bad <- ["poller", {:via, "Registry", :poller}, {:local, :poller}] do
      assert_raise ArgumentError, ~r/:name — ожидается имя процесса/, fn ->
        StartOpts.name!(@label, [name: bad], :name)
      end
    end
  end

  test "shutdown!: неотрицательное целое, :infinity или :brutal_kill" do
    assert StartOpts.shutdown!(@label, [], :shutdown, 30_000) == 30_000

    for good <- [0, 5_000, :infinity, :brutal_kill] do
      assert StartOpts.shutdown!(@label, [shutdown: good], :shutdown, 30_000) == good
    end

    for bad <- [-1, "30s", :kill, nil] do
      assert_raise ArgumentError, ~r/:shutdown — ожидается неотрицательное целое, :infinity или :brutal_kill/, fn ->
        StartOpts.shutdown!(@label, [shutdown: bad], :shutdown, 30_000)
      end
    end
  end

  test "raise_invalid!: своё описание ожидаемого" do
    assert_raise ArgumentError, ~r/:offset — ожидается \{:offset, n\}, получено :bogus/, fn ->
      StartOpts.raise_invalid!(@label, :offset, "{:offset, n}", :bogus)
    end
  end
end
