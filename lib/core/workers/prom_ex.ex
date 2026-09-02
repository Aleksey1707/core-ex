defmodule Core.Workers.PromEx do
  @moduledoc """
  PromEx plugin: polling gauges критичных OTP-процессов (up / mailbox / memory).

  Обязательная опция `watch:` — MFA-провайдер списка процессов
  (`[%{component: String.t(), name: atom()}]`), например
  `{MyApp.PromEx.Workers, :watch_list, []}`.
  """

  use PromEx.Plugin

  alias Core.PromEx.Safe

  @up_event [:prom_ex, :plugin, :workers, :up]
  @mailbox_event [:prom_ex, :plugin, :workers, :message_queue_len]
  @memory_event [:prom_ex, :plugin, :workers, :memory]

  @doc false
  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    watch = Keyword.fetch!(opts, :watch)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :workers))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      Polling.build(
        :workers_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_worker_metrics, [watch]},
        [
          last_value(
            metric_prefix ++ [:up],
            event_name: @up_event,
            description: "Критичный OTP-процесс жив (1) или нет (0)",
            measurement: :value,
            tags: [:component],
            tag_values: &component_tag_values/1
          ),
          last_value(
            metric_prefix ++ [:message_queue_len],
            event_name: @mailbox_event,
            description: "Длина mailbox критичного OTP-процесса",
            measurement: :value,
            tags: [:component],
            tag_values: &component_tag_values/1
          ),
          last_value(
            metric_prefix ++ [:memory, :bytes],
            event_name: @memory_event,
            description: "Память критичного OTP-процесса (байты)",
            measurement: :value,
            tags: [:component],
            tag_values: &component_tag_values/1
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc false
  @spec execute_worker_metrics({module(), atom(), [term()]}) :: :ok

  def execute_worker_metrics({mod, fun, args}) when is_atom(mod) and is_atom(fun) do
    Safe.execute("workers", fn ->
      mod
      |> apply(fun, args)
      |> Enum.each(&emit_process/1)
    end)
  end

  # ---

  defp emit_process(%{component: component, name: name}) do
    meta = %{component: component}

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        emit_alive(pid, meta)

      nil ->
        emit_down(meta)
    end
  end

  defp emit_alive(pid, meta) do
    info = Process.info(pid, [:message_queue_len, :memory]) || []
    mailbox = Keyword.get(info, :message_queue_len, 0)
    memory = Keyword.get(info, :memory, 0)

    :telemetry.execute(@up_event, %{value: 1}, meta)
    :telemetry.execute(@mailbox_event, %{value: mailbox}, meta)
    :telemetry.execute(@memory_event, %{value: memory}, meta)
  end

  defp emit_down(meta) do
    :telemetry.execute(@up_event, %{value: 0}, meta)
    :telemetry.execute(@mailbox_event, %{value: 0}, meta)
    :telemetry.execute(@memory_event, %{value: 0}, meta)
  end

  defp component_tag_values(%{component: component}) do
    %{component: component}
  end
end
