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

  # Фикстура — снимок конверта, который уже уехал в брокер: round-trip меняется вместе с
  # обеими сторонами кодека и переименования не ловит (`14-events-outbox.md`,
  # «Golden-фикстуры»). Файл не перегенерируется.
  test "wire-конверт не менялся: фикстура читается и совпадает с текущим дампом" do
    raw = File.read!(Path.join(__DIR__, "../../../support/fixtures/mq/stream_envelope.json"))

    assert {:ok, decoded} = Stream.Codec.decode(raw)
    assert Mq.Topic.value(decoded.topic) == "products"
    assert Mq.Key.value(decoded.key) == "agg-1"
    assert decoded.body == <<1, 2, 3>>
    assert decoded.headers["name"] == "created"

    assert {:ok, encoded} = Stream.Codec.encode(decoded)
    assert Jason.decode!(encoded) == Jason.decode!(raw)
  end

  test "detail ошибки не содержит разбираемую запись" do
    secret = Base.encode64("пароль-в-теле")

    assert {:error, %{code: :invalid_body, detail: detail}} =
             Stream.Codec.decode(~s({"topic": "products", "body": "#{secret}!"}))

    assert detail == {:redacted, byte_size(secret) + 1}

    assert {:error, %{code: :invalid_payload, detail: %{position: _, token: _}}} =
             Stream.Codec.decode(~s({"topic": ) <> secret)

    assert {:error, %{code: :invalid_headers, detail: :redacted}} =
             Stream.Codec.decode(
               ~s({"topic": "products", "body": "#{secret}", "headers": {"k": 1}})
             )
  end
end
