defmodule Core.Outbox.ReleaseTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureIO

  alias Core.Context
  alias Core.Outbox
  alias Core.Outbox.Record
  alias Core.Outbox.Release

  @repo Core.Config.outbox_repo()

  test "requeue :all возвращает проваленные записи в очередь и сообщает их число оператору" do
    fail_record("f1")
    fail_record("f2")

    assert capture_io(fn -> assert :ok = Release.requeue(:all) end) == "Возвращено в очередь: 2\n"
  end

  test "requeue списка id возвращает только указанные" do
    first = fail_record("f1")
    fail_record("f2")

    assert capture_io(fn -> assert :ok = Release.requeue([first.id]) end) == "Возвращено в очередь: 1\n"
  end

  defp fail_record(name) do
    context = Context.new()
    {:ok, record} = Record.new(Outbox.Topic.new!("orders"), Outbox.Key.new!("agg-1"), Outbox.Name.new!(name), %{})
    :ok = @repo.append([record], context)

    [reserved] = @repo.fetch_and_reserve(Outbox.BatchSize.new!(1), Outbox.LockDuration.new!(30), context)

    {:ok, message} = Outbox.ErrorMessage.create("nope")
    {:ok, at} = Outbox.UpdatedAt.new(DateTime.utc_now())
    {:ok, failed} = Record.record_failure(reserved, message, Outbox.Attempts.new!(1), at)
    :ok = @repo.save_results([failed], context)

    failed
  end
end
