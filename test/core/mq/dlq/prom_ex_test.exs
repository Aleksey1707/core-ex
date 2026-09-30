defmodule Core.Mq.Dlq.PromExTest do
  use Core.DataCase, async: false

  alias Core.Mq.Dlq.Store
  alias Core.Mq.PromEx

  test "с dlq_repo строится группа dlq_count по подписчику, топику и статусу" do
    assert [%{metrics: [metric]}] = PromEx.polling_metrics(otp_app: :core, dlq_repo: TestRepo)

    assert metric.name == [:core, :prom_ex, :mq, :dlq, :count]
    assert metric.tags == [:subscriber, :topic, :status]
  end

  test "без dlq_repo и readers группы нет" do
    assert [] = PromEx.polling_metrics(otp_app: :core)
  end

  test "execute_dlq_metrics эмитит число записей по статусам" do
    Store.insert(TestRepo, %{
      subscriber: "promex",
      topic: "orders",
      key: nil,
      header_names: [],
      header_values: [],
      body: "a",
      partition: nil,
      offset: nil,
      reason: nil,
      error: nil,
      attempts: nil
    })

    handler_id = "mq-dlq-promex-#{inspect(self())}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :mq, :dlq, :count],
        fn _event, measurements, metadata, _config -> send(parent, {:dlq_count, metadata, measurements.value}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = PromEx.execute_dlq_metrics(TestRepo)

    assert_received {:dlq_count, %{subscriber: "promex", topic: "orders", status: "dead"}, 1}
    assert_received {:dlq_count, %{subscriber: "promex", topic: "orders", status: "requeued"}, 0}
    assert_received {:dlq_count, %{subscriber: "promex", topic: "orders", status: "processed"}, 0}
  end
end
