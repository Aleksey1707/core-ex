defmodule Core.Mq.Stream.CodecTest do
  use ExUnit.Case, async: true

  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Mq.Stream

  test "round-trip сохраняет топик, заголовки, бинарное тело и ключ" do
    assert {:ok, msg} =
             Message.new(
               Mq.Topic.new!("products"),
               %{"name" => "created"},
               <<1, 2, 3>>,
               Mq.Key.new!("k1")
             )

    assert {:ok, encoded} = Stream.Codec.encode(msg)
    assert {:ok, decoded} = Stream.Codec.decode(encoded)
    assert decoded.topic == msg.topic
    assert decoded.headers == msg.headers
    assert decoded.body == msg.body
    assert decoded.key == msg.key
  end

  test "round-trip сообщения без ключа" do
    assert {:ok, msg} = Message.new(Mq.Topic.new!("products"), %{}, "body")

    assert {:ok, encoded} = Stream.Codec.encode(msg)
    assert {:ok, decoded} = Stream.Codec.decode(encoded)
    assert decoded.key == nil
    assert decoded.headers == %{}
  end

  test "decode отклоняет чужой payload" do
    assert {:error, %{code: :invalid_payload}} = Stream.Codec.decode("не json")
    assert {:error, %{code: :invalid_payload}} = Stream.Codec.decode(~s(["не объект"]))
    assert {:error, %{code: :invalid_body}} = Stream.Codec.decode(~s({"body": 1}))
  end
end
