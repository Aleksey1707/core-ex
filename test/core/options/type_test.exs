defmodule Core.Options.TypeTest do
  use ExUnit.Case, async: true

  alias Core.Mq
  alias Core.Options.Type

  describe "custom-типы схемы" do
    test "prim: структура ожидаемого модуля" do
      topic = Mq.Topic.new!("products")

      assert Type.prim(topic, Mq.Topic) == {:ok, topic}
      assert Type.prim("products", Mq.Topic) == {:error, ~s(ожидается %Core.Mq.Topic{}, получено "products")}
      assert {:error, "ожидается %Core.Mq.Topic{}, получено " <> _} = Type.prim(Mq.Key.new!("agg-1"), Mq.Topic)
    end

    test "module: атом, кроме nil" do
      assert Type.module(MyConn) == {:ok, MyConn}
      assert Type.module(nil) == {:error, "ожидается модуль, получено nil"}
      assert Type.module("MyConn") == {:error, ~s(ожидается модуль, получено "MyConn")}
    end

    test "term: любое значение, кроме nil" do
      assert Type.term(:reader) == {:ok, :reader}
      assert Type.term(false) == {:ok, false}
      assert Type.term(nil) == {:error, "ожидается значение, получено nil"}
    end

    test "atom: атом, кроме nil" do
      assert Type.atom(:poller) == {:ok, :poller}
      assert Type.atom(nil) == {:error, "ожидается атом, получено nil"}
      assert Type.atom("poller") == {:error, ~s(ожидается атом, получено "poller")}
    end

    test "binary: непустая строка" do
      assert Type.binary("stream") == {:ok, "stream"}
      assert Type.binary("") == {:error, ~s(ожидается непустая строка, получено "")}
      assert Type.binary(:stream) == {:error, "ожидается непустая строка, получено :stream"}
    end
  end

  describe "prim_option/2" do
    @schema [topic: Type.prim_option(Mq.Topic, "Топик.")]

    test "обязательный ключ проверяется prim/2" do
      topic = Mq.Topic.new!("products")

      assert NimbleOptions.validate([topic: topic], @schema) == {:ok, [topic: topic]}

      assert {:error, %NimbleOptions.ValidationError{message: message}} = NimbleOptions.validate([], @schema)
      assert message =~ "required :topic option not found"

      assert {:error, %NimbleOptions.ValidationError{message: message}} =
               NimbleOptions.validate([topic: "products"], @schema)

      assert message =~ "invalid value for :topic option: ожидается %Core.Mq.Topic{}"
    end

    test "описание: тип и doc" do
      assert Core.Options.docs(@schema) =~ "`:topic` (`t:Core.Mq.Topic.t/0`) - Required. Топик."
    end
  end
end
