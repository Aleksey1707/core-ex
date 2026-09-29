defmodule Core.PromEx.SafeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Core.PromEx.Safe

  @plugin :safe_test

  setup do
    handler_id = "safe-test-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        Safe.error_event(@plugin),
        fn _event, measurements, metadata, test_pid -> send(test_pid, {:collect_error, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "execute/4" do
    test "исключение источника — событие отказа с collector и warning как раньше" do
      log = capture_log(fn -> assert :ok = Safe.execute(@plugin, :queue, "safe queue", fn -> raise "down" end) end)

      assert log =~ "PromEx: сбор метрик пропущен (safe queue)"
      assert_receive {:collect_error, %{count: 1}, %{collector: :queue}}
    end

    test "exit источника — событие отказа с collector" do
      log = capture_log(fn -> assert :ok = Safe.execute(@plugin, :queue, "safe queue", fn -> exit(:noproc) end) end)

      assert log =~ "exit reason=:noproc"
      assert_receive {:collect_error, %{count: 1}, %{collector: :queue}}
    end

    test "успешный сбор — без события отказа" do
      assert :ok = Safe.execute(@plugin, :queue, "safe queue", fn -> :done end)
      refute_received {:collect_error, _, _}
    end
  end

  describe "collect/4" do
    test "исключение и exit — [] и событие отказа на каждый сбой" do
      capture_log(fn ->
        assert [] = Safe.collect(@plugin, :readers, "safe reader a", fn -> raise "down" end)
        assert [] = Safe.collect(@plugin, :readers, "safe reader b", fn -> exit(:timeout) end)
      end)

      assert_receive {:collect_error, %{count: 1}, %{collector: :readers}}
      assert_receive {:collect_error, %{count: 1}, %{collector: :readers}}
    end

    test "успешный сбор — значения без события отказа" do
      assert [1, 2] = Safe.collect(@plugin, :readers, "safe reader", fn -> [1, 2] end)
      refute_received {:collect_error, _, _}
    end
  end

  test "error_metric — счётчик <префикс>.collect.errors.total по collector на событии плагина" do
    metric = Safe.error_metric([:core, :prom_ex, :safe_test], @plugin)

    assert %Telemetry.Metrics.Counter{} = metric
    assert metric.name == [:core, :prom_ex, :safe_test, :collect, :errors, :total]
    assert metric.event_name == Safe.error_event(@plugin)
    assert metric.tags == [:collector]
    assert metric.tag_values.(%{collector: :queue}) == %{collector: "queue"}
  end
end
