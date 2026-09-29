defmodule Core.Workers.PromExTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Core.Workers.PromEx

  defmodule StubWorker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
    def init(:ok), do: {:ok, %{}}
  end

  defmodule StubWatch do
    def empty, do: []

    def one(component, name), do: [%{component: component, name: name}]

    def many(items), do: items

    def from(agent), do: Agent.get(agent, & &1)

    def down, do: exit(:noproc)
  end

  defmodule RemoteRegistry do
    # pid другой ноды: имя ноды во внешнем формате заменено строкой той же длины.
    def whereis_name(_name) do
      self()
      |> :erlang.term_to_binary()
      |> :binary.replace(Atom.to_string(node()), String.duplicate("r", byte_size(Atom.to_string(node()))))
      |> :erlang.binary_to_term()
    end
  end

  setup do
    on_exit(fn ->
      for {{Core.PromEx.Labels, _source} = key, _value} <- :persistent_term.get(), do: :persistent_term.erase(key)
    end)
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

  test "event_metrics содержит workers.collect.errors.total" do
    assert [%{metrics: metrics}] = PromEx.event_metrics(otp_app: :core)
    assert Enum.map(metrics, &Enum.join(&1.name, ".")) == ["core.prom_ex.workers.collect.errors.total"]
  end

  test "отказ провайдера watch: — отказ сбора workers" do
    handler_id = "workers-promex-collect-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:prom_ex, :plugin, :workers, :collect, :error],
        fn _event, measurements, metadata, test_pid -> send(test_pid, {:collect_error, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log = capture_log(fn -> assert :ok = PromEx.execute_worker_metrics({StubWatch, :down, []}) end)

    assert log =~ "сбор метрик пропущен (workers)"
    assert_received {:collect_error, %{count: 1}, %{collector: :workers}}
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

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 0}, %{component: "stub_component"}}
  end

  test "execute_worker_metrics эмитит up=1 для живого named процесса" do
    name = :"workers_promex_stub_#{System.unique_integer([:positive])}"
    start_supervised!({StubWorker, name: name})

    attach_up_handler("workers-promex-alive-#{inspect(self())}")

    PromEx.execute_worker_metrics({StubWatch, :one, ["stub_component", name]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1}, %{component: "stub_component"}}
  end

  test "execute_worker_metrics: процесс под {:via, Registry, _} — up 1 живой, 0 остановленный" do
    registry = :"workers_promex_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    name = {:via, Registry, {registry, :worker}}
    start_supervised!({StubWorker, name: name})
    attach_up_handler("workers-promex-via-#{inspect(self())}")

    PromEx.execute_worker_metrics({StubWatch, :one, ["via_component", name]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1}, %{component: "via_component"}}

    :ok = stop_supervised!(StubWorker)

    PromEx.execute_worker_metrics({StubWatch, :one, ["via_component", name]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 0}, %{component: "via_component"}}
  end

  test "execute_worker_metrics: процесс под {:global, _} — up 1" do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    start_supervised!({StubWorker, name: name})
    attach_up_handler("workers-promex-global-#{inspect(self())}")

    PromEx.execute_worker_metrics({StubWatch, :one, ["global_component", name]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1}, %{component: "global_component"}}
  end

  test "execute_worker_metrics: незапущенный реестр {:via, _} — up 0, соседний элемент цикла собран" do
    alive = :"workers_promex_alive_#{System.unique_integer([:positive])}"
    start_supervised!({StubWorker, name: alive})
    registry = :"workers_promex_absent_registry_#{System.unique_integer([:positive])}"
    attach_up_handler("workers-promex-via-absent-#{inspect(self())}")

    watch =
      {StubWatch, :many,
       [[%{component: "via_absent", name: {:via, Registry, {registry, :worker}}}, %{component: "atom", name: alive}]]}

    assert capture_log(fn -> assert :ok = PromEx.execute_worker_metrics(watch) end) == ""

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 0}, %{component: "via_absent"}}
    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1}, %{component: "atom"}}
  end

  test "execute_worker_metrics: процесс на другой ноде — up 1, mailbox и memory 0" do
    attach_handler("workers-promex-remote-#{inspect(self())}", [
      [:prom_ex, :plugin, :workers, :up],
      [:prom_ex, :plugin, :workers, :message_queue_len],
      [:prom_ex, :plugin, :workers, :memory]
    ])

    PromEx.execute_worker_metrics({StubWatch, :one, ["remote", {:via, RemoteRegistry, :worker}]})

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1}, %{component: "remote"}}
    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :message_queue_len], %{value: 0}, %{component: "remote"}}
    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :memory], %{value: 0}, %{component: "remote"}}
  end

  test "повтор метки: up — минимум, error в лог один раз на набор повторов" do
    alive = :"workers_promex_alive_#{System.unique_integer([:positive])}"
    absent = :"workers_promex_absent_#{System.unique_integer([:positive])}"
    start_supervised!({StubWorker, name: alive})
    attach_up_handler("workers-promex-dup-#{inspect(self())}")

    watch = {StubWatch, :many, [[%{component: "twin", name: alive}, %{component: "twin", name: absent}]]}

    log = capture_log(fn -> PromEx.execute_worker_metrics(watch) end)

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 0}, %{component: "twin"}}
    refute_received {:telemetry, [:prom_ex, :plugin, :workers, :up], %{value: 1}, %{component: "twin"}}
    assert log =~ "PromEx: метка повторяется, значения сведены: source=workers"
    assert log =~ inspect(absent)

    assert capture_log(fn -> PromEx.execute_worker_metrics(watch) end) == ""
  end

  test "повтор метки: порядок элементов в списке набор повторов не меняет" do
    items = [%{component: "twin", name: :workers_promex_a}, %{component: "twin", name: :workers_promex_b}]
    agent = start_supervised!({Agent, fn -> items end})
    watch = {StubWatch, :from, [agent]}

    assert capture_log(fn -> PromEx.execute_worker_metrics(watch) end) =~ "метка повторяется"

    Agent.update(agent, &Enum.reverse/1)
    assert capture_log(fn -> PromEx.execute_worker_metrics(watch) end) == ""
  end

  test "повтор метки: mailbox — максимум, memory — сумма; экземпляры плагина помнят повторы раздельно" do
    first = :"workers_promex_first_#{System.unique_integer([:positive])}"
    second = :"workers_promex_second_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: :first, start: {StubWorker, :start_link, [[name: first]]}})
    start_supervised!(%{id: :second, start: {StubWorker, :start_link, [[name: second]]}})
    :sys.suspend(first)
    send(Process.whereis(first), :queued)

    attach_handler("workers-promex-fold-#{inspect(self())}", [
      [:prom_ex, :plugin, :workers, :message_queue_len],
      [:prom_ex, :plugin, :workers, :memory]
    ])

    twins = {StubWatch, :many, [[%{component: "twin", name: first}, %{component: "twin", name: second}]]}
    single = {StubWatch, :one, ["single", first]}
    {:memory, second_memory} = Process.info(Process.whereis(second), :memory)

    log =
      capture_log(fn ->
        PromEx.execute_worker_metrics(twins)
        PromEx.execute_worker_metrics(single)
        PromEx.execute_worker_metrics(twins)
      end)

    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :message_queue_len], %{value: mailbox},
                    %{component: "twin"}}

    assert mailbox >= 1
    assert_receive {:telemetry, [:prom_ex, :plugin, :workers, :memory], %{value: total}, %{component: "twin"}}
    assert total >= second_memory
    assert length(String.split(log, "метка повторяется")) == 2
  end

  defp attach_up_handler(handler_id), do: attach_handler(handler_id, [[:prom_ex, :plugin, :workers, :up]])

  defp attach_handler(handler_id, events) do
    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
