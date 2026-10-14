defmodule Mix.Tasks.Outbox.RequeueTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureIO

  alias Core.Context
  alias Core.Outbox
  alias Core.Outbox.Record
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

  test "run возвращает failed-записи в очередь и сообщает их число" do
    repo = Core.Config.outbox_repo()
    context = Context.new()

    {:ok, record} =
      Record.new(Outbox.Topic.new!("products"), Outbox.Key.new!("agg-1"), Outbox.Name.new!("f1"), %{}, nil, nil)

    assert :ok = repo.append([record], context)
    [reserved] = repo.fetch_and_reserve(Outbox.BatchSize.new!(1), Outbox.LockDuration.new!(30), context)
    {:ok, message} = Outbox.ErrorMessage.create("nope")
    {:ok, at} = Outbox.UpdatedAt.new(DateTime.utc_now())
    {:ok, failed} = Record.record_failure(reserved, message, Outbox.Attempts.new!(1), at)
    assert :ok = repo.save_results([failed], context)

    assert capture_io(fn -> Requeue.run(["--all"]) end) == "Возвращено в очередь: 1\n"
  end
end
