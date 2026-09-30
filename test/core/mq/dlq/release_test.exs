defmodule Core.Mq.Dlq.ReleaseTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureIO

  alias Core.Mq.Dlq.Release
  alias Core.Mq.Dlq.Store

  test "requeue возвращает записи и сообщает их число оператору" do
    for body <- ~w(a b) do
      Store.insert(TestRepo, %{
        subscriber: "release",
        topic: "orders",
        key: nil,
        header_names: [],
        header_values: [],
        body: body,
        partition: nil,
        offset: nil,
        reason: nil,
        error: nil,
        attempts: nil
      })
    end

    assert capture_io(fn -> assert :ok = Release.requeue(TestRepo, :all) end) == "Возвращено в обработку: 2\n"
  end
end
