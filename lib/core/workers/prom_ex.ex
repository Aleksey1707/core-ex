defmodule Core.Workers.PromEx do
  @moduledoc """
  PromEx plugin: polling gauges критичных OTP-процессов (up / mailbox / memory).

  Обязательная опция `watch:` — MFA-провайдер списка процессов
  (`[%{component: String.t(), name: atom()}]`), например
  `{MyApp.PromEx.Workers, :watch_list, []}`.

  Элементы с одной меткой `component` сводятся в одно значение: `up` — минимум (любой мёртвый
  процесс даёт 0), `message_queue_len` — максимум, `memory` — сумма; повтор — `error` в лог
  (`Core.PromEx.Labels`).
  """

  use PromEx.Plugin

  alias Core.PromEx.Labels
  alias Core.PromEx.Safe

  @up_event [:prom_ex, :plugin, :workers, :up]
  @mailbox_event [:prom_ex, :plugin, :workers, :message_queue_len]
  @memory_event [:prom_ex, :plugin, :workers, :memory]

  @doc false
  @spec event_metrics(keyword()) :: [Event.t()]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :workers))

    [
      Event.build(:workers_collect_event_metrics, [Safe.error_metric(metric_prefix, :workers)])
    ]
  end

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
    Safe.execute(:workers, :workers, "workers", fn ->
      groups =
        mod
        |> apply(fun, args)
        |> Labels.group(& &1.component)

      Labels.report("workers mfa=#{inspect({mod, fun, args})}", groups)
      Enum.each(groups, &emit_component/1)
    end)
  end

  # ---

  defp emit_component({component, items}) do
    samples = Enum.map(items, &sample/1)
    meta = %{component: component}

    :telemetry.execute(@up_event, %{value: Enum.min(values(samples, :up))}, meta)
    :telemetry.execute(@mailbox_event, %{value: Enum.max(values(samples, :mailbox))}, meta)
    :telemetry.execute(@memory_event, %{value: Enum.sum(values(samples, :memory))}, meta)
  end

  defp values(samples, key), do: Enum.map(samples, &Map.fetch!(&1, key))

  defp sample(%{name: name}) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> alive_sample(pid)
      nil -> %{up: 0, mailbox: 0, memory: 0}
    end
  end

  # Процесс мог умереть между `whereis` и `info`: `nil` — тот же сэмпл, что у отсутствующего.
  defp alive_sample(pid) do
    case Process.info(pid, [:message_queue_len, :memory]) do
      [message_queue_len: mailbox, memory: memory] -> %{up: 1, mailbox: mailbox, memory: memory}
      nil -> %{up: 0, mailbox: 0, memory: 0}
    end
  end

  defp component_tag_values(%{component: component}) do
    %{component: component}
  end
end
