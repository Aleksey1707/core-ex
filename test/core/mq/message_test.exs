defmodule Core.Mq.MessageTest do
  use ExUnit.Case, async: true

  alias Core.Mq
  alias Core.Mq.Codec
  alias Core.Mq.Message

  test "new нормализует headers в lowercase" do
    assert {:ok, msg} =
             Message.new(
               Mq.Topic.new!("products"),
               %{"Name" => "created", "Aggr_Id" => "abc"},
               "body",
               Mq.Key.new!("agg-1")
             )

    assert msg.headers == %{"name" => "created", "aggr_id" => "abc"}
    assert {:ok, "created"} = Message.get_header(msg, Mq.HeaderKey.new!("name"))
    assert Message.find_header(msg, Mq.HeaderKey.new!("missing")) == nil
  end

  test "new отклоняет невалидный header key" do
    assert {:error, _} =
             Message.new(
               Mq.Topic.new!("products"),
               %{"bad key!" => "x"},
               "body"
             )
  end

  test "codec round-trip" do
    assert {:ok, msg} =
             Message.new(
               Mq.Topic.new!("products"),
               %{"name" => "created"},
               <<1, 2, 3>>,
               Mq.Key.new!("k1")
             )

    assert {:ok, encoded} = Codec.encode(msg)
    assert {:ok, decoded} = Codec.decode(encoded)
    assert decoded.topic == msg.topic
    assert decoded.headers == msg.headers
    assert decoded.body == msg.body
    assert decoded.key == msg.key
  end
end
