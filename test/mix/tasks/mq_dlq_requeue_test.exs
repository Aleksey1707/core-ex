defmodule Mix.Tasks.Mq.Dlq.RequeueTest do
  use ExUnit.Case, async: true

  alias Core.Mq
  alias Mix.Tasks.Mq.Dlq.Requeue

  test "--all → :all" do
    assert Requeue.parse!(["--all"]) == {:all, nil}
  end

  test "--topic → топик" do
    assert Requeue.parse!(["--topic", "orders"]) == {{:topic, Mq.Topic.new!("orders")}, nil}
  end

  test "--id собирает список идентификаторов" do
    assert Requeue.parse!(["--id", "42", "--id", "43"]) == {[42, 43], nil}
  end

  test "--repo — имя репозитория" do
    assert Requeue.parse!(["--all", "--repo", "MyApp.Repo"]) == {:all, "MyApp.Repo"}
  end

  test "без цели — ошибка" do
    assert_raise Mix.Error, ~r/укажите --all/, fn -> Requeue.parse!([]) end
  end

  test "цели взаимоисключающи" do
    assert_raise Mix.Error, ~r/взаимоисключающи/, fn -> Requeue.parse!(["--all", "--topic", "orders"]) end
    assert_raise Mix.Error, ~r/взаимоисключающи/, fn -> Requeue.parse!(["--topic", "orders", "--id", "1"]) end
  end

  test "невалидные --id и --topic — ошибка" do
    assert_raise Mix.Error, ~r/--id 0/, fn -> Requeue.parse!(["--id", "0"]) end
    assert_raise Mix.Error, ~r/--id abc/, fn -> Requeue.parse!(["--id", "abc"]) end
    assert_raise Mix.Error, ~r/--topic a b/, fn -> Requeue.parse!(["--topic", "a b"]) end
  end
end
