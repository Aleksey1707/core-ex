defmodule Core.Mq.MessageTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Mq
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

  test "new принимает заголовки списком пар: повтор имени — последнее значение, null — пустая строка" do
    headers = [{"Trace", "a"}, {"trace", "b"}, {"empty", nil}]

    assert {:ok, msg} = Message.new(Mq.Topic.new!("products"), headers, "body")
    assert msg.headers == %{"trace" => "b", "empty" => ""}
  end

  test "new отклоняет пустое имя заголовка и имя не в UTF-8" do
    for name <- ["", <<0xFF>>] do
      assert {:error, %Error{}} = Message.new(Mq.Topic.new!("products"), %{name => "x"}, "body")
    end
  end

  test "имя заголовка — любая непустая строка UTF-8" do
    assert {:ok, msg} = Message.new(Mq.Topic.new!("products"), %{"Content Type: v1!" => "x"}, "body")
    assert msg.headers == %{"content type: v1!" => "x"}
  end

  test "nil-тело — tombstone, позиция по умолчанию nil" do
    assert {:ok, %Message{body: nil, position: nil}} = Message.new(Mq.Topic.new!("products"), %{}, nil)
  end

  test "new принимает позицию источника" do
    position = %Mq.Position{partition: 3, offset: 42}

    assert {:ok, %Message{position: ^position}} =
             Message.new(Mq.Topic.new!("products"), %{}, "body", nil, position)
  end

  describe "Mq.Key" do
    test "непустые байты без ограничения длины и UTF-8" do
      avro = <<0, 0, 0, 0, 1, 0xFF, 0xFE>>
      long = String.duplicate("k", 10_000)

      assert Mq.Key.value(Mq.Key.new!(avro)) == avro
      assert Mq.Key.value(Mq.Key.new!(long)) == long
    end

    test "пустое значение и не-binary — ошибка" do
      assert {:error, %Error{}} = Mq.Key.new("")
      assert {:error, %Error{}} = Mq.Key.new(1)
    end
  end
end
