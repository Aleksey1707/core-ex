defmodule Core.Workers.PromExTest do
  use ExUnit.Case, async: false

  alias Core.Workers.PromEx

  defmodule StubWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
    def init(:ok), do: {:ok, %{}}
  end

  defmodule StubWatch do
    def empty, do: []

    def one(component, name), do: [%{component: component, name: name}]
  end

  test "polling_metrics содержит workers.up" do
    opts = [otp_app: :core, poll_rate: 5_000, watch: {StubWatch, :empty, []}]

    assert [%{metrics: poll_metrics, poll_rate: 5_000}] =
             List.wrap(PromEx.polling_metrics(opts))

    names =
      poll_metrics
      |> Enum.map(&Enum.join(&1.name, "."))

    assert Enum.any?(names, &String.contains?(&1, "workers.up"))
    assert Enum.any?(names, &String.contains?(&1, "workers.message_queue_len"))
    assert Enum.any?(names, &String.contains?(&1, "workers.memory"))
  end

  test "polling_metrics требует watch:" do
    assert_raise KeyError, fn ->
      PromEx.polling_metrics(otp_app: :core, poll_rate: 5_000)
    end
  end

  test "execute_worker_metrics эмитит up=0 для отсутствующего процесса" do
    attach_up_handler("workers-promex-down-#{inspect(self())}")

    name = :"workers_promex_absent_#{System.unique_integer([:positive])}"
    PromEx.execute_worker_metrics({StubWatch, :one, ["stub_component", name]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 0},
                    %{component: "stub_component"}}
  end

  test "execute_worker_metrics эмитит up=1 для живого named процесса" do
    name = :"workers_promex_stub_#{System.unique_integer([:positive])}"
    start_supervised!({StubWorker, name: name})

    attach_up_handler("workers-promex-alive-#{inspect(self())}")

    PromEx.execute_worker_metrics({StubWatch, :one, ["stub_component", name]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1},
                    %{component: "stub_component"}}
  end

  defp attach_up_handler(handler_id) do
    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :workers, :up],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
