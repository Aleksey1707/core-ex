defmodule Core.Helper.StartOptsTest do
  use ExUnit.Case, async: true

  alias Core.Helper.StartOpts
  alias Core.Mq

  @label "Test.Process"

  describe "custom-валидаторы схемы" do
    test "prim: структура ожидаемого модуля" do
      topic = Mq.Topic.new!("products")

      assert StartOpts.prim(topic, Mq.Topic) == {:ok, topic}
      assert StartOpts.prim("products", Mq.Topic) == {:error, ~s(ожидается %Core.Mq.Topic{}, получено "products")}
      assert {:error, "ожидается %Core.Mq.Topic{}, получено " <> _} = StartOpts.prim(Mq.Key.new!("agg-1"), Mq.Topic)
    end

    test "module: атом, кроме nil" do
      assert StartOpts.module(MyConn) == {:ok, MyConn}
      assert StartOpts.module(nil) == {:error, "ожидается модуль, получено nil"}
      assert StartOpts.module("MyConn") == {:error, ~s(ожидается модуль, получено "MyConn")}
    end

    test "term: любое значение, кроме nil" do
      assert StartOpts.term(:reader) == {:ok, :reader}
      assert StartOpts.term(false) == {:ok, false}
      assert StartOpts.term(nil) == {:error, "ожидается значение, получено nil"}
    end

    test "atom: атом, кроме nil" do
      assert StartOpts.atom(:poller) == {:ok, :poller}
      assert StartOpts.atom(nil) == {:error, "ожидается атом, получено nil"}
      assert StartOpts.atom("poller") == {:error, ~s(ожидается атом, получено "poller")}
    end

    test "binary: непустая строка" do
      assert StartOpts.binary("stream") == {:ok, "stream"}
      assert StartOpts.binary("") == {:error, ~s(ожидается непустая строка, получено "")}
      assert StartOpts.binary(:stream) == {:error, "ожидается непустая строка, получено :stream"}
    end

    test "name: имя процесса или nil" do
      for good <- [nil, :poller, {:global, :poller}, {:via, Registry, {:r, 1}}] do
        assert StartOpts.name(good) == {:ok, good}
      end

      for bad <- ["poller", {:via, "Registry", :poller}, {:local, :poller}] do
        assert {:error, "ожидается имя процесса (атом, {:global, term} или {:via, module, term}), получено " <> _} =
                 StartOpts.name(bad)
      end
    end

    test "topics_filter: :all, {:only, строки} или {:except, строки}" do
      for good <- [:all, {:only, ["orders"]}, {:except, []}] do
        assert StartOpts.topics_filter(good) == {:ok, good}
      end

      for bad <- [["orders"], {:only, "orders"}, {:only, [:orders]}, {:all, ["orders"]}, nil] do
        assert {:error, "ожидается :all, {:only, [String.t()]} или {:except, [String.t()]}, получено " <> _} =
                 StartOpts.topics_filter(bad)
      end
    end

    test "shutdown: неотрицательное целое, :infinity или :brutal_kill" do
      for good <- [0, 5_000, :infinity, :brutal_kill] do
        assert StartOpts.shutdown(good) == {:ok, good}
      end

      for bad <- [-1, "30s", :kill, nil] do
        assert {:error, "ожидается неотрицательное целое, :infinity или :brutal_kill, получено " <> _} =
                 StartOpts.shutdown(bad)
      end
    end
  end

  test "process!: {модуль, опции} с name: атомом, иначе ошибка с именем опции" do
    assert StartOpts.process!(@label, :writer, {MyWriter, name: MyWriter.Name, prefix: "p"}) ==
             %{module: MyWriter, opts: [name: MyWriter.Name, prefix: "p"], name: MyWriter.Name}

    for spec <- [{MyWriter, []}, {MyWriter, name: "w"}, {nil, name: :w}, {MyWriter, :w}, MyWriter] do
      assert_raise ArgumentError, ~r/:writer — ожидается \{модуль, опции с name: атомом\}/, fn ->
        StartOpts.process!(@label, :writer, spec)
      end
    end
  end

  test "unique!: повторы — ошибка с их списком" do
    assert StartOpts.unique!(@label, :pollers, "имена без повторов", [:a, :b]) == :ok

    assert_raise ArgumentError, ~r/:pollers — ожидается имена без повторов, получено \[:a\]/, fn ->
      StartOpts.unique!(@label, :pollers, "имена без повторов", [:a, :b, :a, :a])
    end
  end
end
