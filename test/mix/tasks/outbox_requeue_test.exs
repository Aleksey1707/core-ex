defmodule Mix.Tasks.Outbox.RequeueTest do
  use ExUnit.Case, async: true

  alias Core.Outbox
  alias Mix.Tasks.Outbox.Requeue

  @uuid "0199c0e2-0000-7000-8000-000000000000"

  test "--all → :all" do
    assert Requeue.parse_target!(["--all"]) == :all
  end

  test "--id собирает список идентификаторов" do
    assert [%Outbox.ID{} = id] = Requeue.parse_target!(["--id", @uuid])
    assert Outbox.ID.format(id, :full) == @uuid

    assert [_, _] =
             Requeue.parse_target!([
               "--id",
               @uuid,
               "--id",
               "0199c0e2-0000-7000-8000-000000000001"
             ])
  end

  test "без аргументов — ошибка" do
    assert_raise Mix.Error, ~r/укажите --all/, fn -> Requeue.parse_target!([]) end
  end

  test "--all вместе с --id — ошибка" do
    assert_raise Mix.Error, ~r/взаимоисключающи/, fn ->
      Requeue.parse_target!(["--all", "--id", @uuid])
    end
  end

  test "невалидный --id — ошибка" do
    assert_raise Mix.Error, ~r/--id not-a-uuid/, fn ->
      Requeue.parse_target!(["--id", "not-a-uuid"])
    end
  end
end
