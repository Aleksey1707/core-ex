defmodule Core.Cgroup.PromEx do
  @moduledoc """
  PromEx plugin: polling gauges cgroup memory (`memory.current`, `memory.stat`
  и `memory.max`).

  Опции `current_path:` / `stat_path:` / `max_path:` — явные пути к файлам; без них путь
  берётся из cgroup процесса (`Core.Cgroup`). Без лимита утилизацию посчитать не из
  чего, поэтому `memory.max` публикуется отдельным gauge (при `max` лимите — метрика не
  эмитится, а не пишется нулём).

  `memory.current` считает вместе со страничным кешем прочитанных файлов, поэтому
  после массового чтения с диска он остаётся высоким и расходится с `podman stats`.
  Память приложения — `memory.anon` (то же значение, что в `podman stats`).
  """

  use PromEx.Plugin

  alias Core.Cgroup

  @memory_event [:prom_ex, :plugin, :cgroup, :memory]
  @memory_anon_event [:prom_ex, :plugin, :cgroup, :memory_anon]
  @memory_max_event [:prom_ex, :plugin, :cgroup, :memory_max]

  @doc false
  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :cgroup))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)
    memory_opts = Keyword.take(opts, [:current_path, :stat_path, :max_path, :mount_point])

    [
      Polling.build(
        :cgroup_memory_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_memory_metrics, [memory_opts]},
        [
          last_value(
            metric_prefix ++ [:memory, :current, :bytes],
            event_name: @memory_event,
            description: "Cgroup memory.current (ОЗУ контейнера вместе со страничным кешем)",
            measurement: :bytes
          ),
          last_value(
            metric_prefix ++ [:memory, :anon, :bytes],
            event_name: @memory_anon_event,
            description: "Cgroup memory.stat anon (память контейнера без страничного кеша)",
            measurement: :bytes
          ),
          last_value(
            metric_prefix ++ [:memory, :max, :bytes],
            event_name: @memory_max_event,
            description: "Cgroup memory.max (лимит памяти контейнера)",
            measurement: :bytes
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc false
  @spec execute_memory_metrics(keyword()) :: :ok

  def execute_memory_metrics(memory_opts) when is_list(memory_opts) do
    emit_current(memory_opts)
    emit_anon(memory_opts)
    emit_max(memory_opts)
  end

  # ---

  defp emit_current(memory_opts) do
    case Cgroup.memory_current(memory_opts) do
      {:ok, bytes} -> :telemetry.execute(@memory_event, %{bytes: bytes}, %{})
      :unavailable -> :ok
    end
  end

  defp emit_anon(memory_opts) do
    case Cgroup.memory_anon(memory_opts) do
      {:ok, bytes} -> :telemetry.execute(@memory_anon_event, %{bytes: bytes}, %{})
      :unavailable -> :ok
    end
  end

  defp emit_max(memory_opts) do
    case Cgroup.memory_max(memory_opts) do
      {:ok, bytes} -> :telemetry.execute(@memory_max_event, %{bytes: bytes}, %{})
      :unlimited -> :ok
      :unavailable -> :ok
    end
  end
end
