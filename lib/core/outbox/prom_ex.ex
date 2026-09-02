defmodule Core.Outbox.PromEx do
  @moduledoc """
  PromEx plugin: event-метрики Poller/Cleaner и polling gauges очереди outbox.
  """

  use PromEx.Plugin

  alias Core.Outbox
  alias Core.PromEx.Safe
  alias Core.Telemetry

  @queue_count_event [:prom_ex, :plugin, :outbox, :queue, :count]
  @oldest_age_event [:prom_ex, :plugin, :outbox, :queue, :oldest_age]
  @expired_locks_event [:prom_ex, :plugin, :outbox, :queue, :expired_locks]

  @duration_buckets [1, 10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @doc false
  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :outbox))
    duration_unit = Keyword.get(opts, :duration_unit, :millisecond)
    duration_unit_plural = PromEx.Utils.make_plural_atom(duration_unit)

    [
      Event.build(
        :outbox_event_metrics,
        [
          counter(
            metric_prefix ++ [:poller, :cycles, :total],
            event_name: poller_cycle_event(),
            description: "Число циклов outbox poller",
            tags: [:result],
            tag_values: &result_tag_values/1
          ),
          distribution(
            metric_prefix ++ [:poller, :duration, duration_unit_plural],
            event_name: poller_cycle_event(),
            measurement: :duration,
            description: "Длительность цикла outbox poller",
            reporter_options: [buckets: @duration_buckets],
            tags: [:result],
            tag_values: &result_tag_values/1,
            unit: {:native, duration_unit}
          ),
          sum(
            metric_prefix ++ [:poller, :batch_size],
            event_name: poller_cycle_event(),
            measurement: :batch_size,
            description: "Размер пакета, обработанного poller за цикл",
            tags: [:result],
            tag_values: &result_tag_values/1
          ),
          sum(
            metric_prefix ++ [:poller, :published, :total],
            event_name: poller_cycle_event(),
            measurement: :published,
            description: "Число успешно опубликованных записей outbox за цикл poller",
            tags: [:result],
            tag_values: &result_tag_values/1
          ),
          sum(
            metric_prefix ++ [:poller, :retry, :total],
            event_name: poller_cycle_event(),
            measurement: :retry,
            description: "Число записей outbox на повтор за цикл poller",
            tags: [:result],
            tag_values: &result_tag_values/1
          ),
          sum(
            metric_prefix ++ [:poller, :failed, :total],
            event_name: poller_cycle_event(),
            measurement: :failed,
            description: "Число терминально проваленных записей outbox за цикл poller",
            tags: [:result],
            tag_values: &result_tag_values/1
          ),
          counter(
            metric_prefix ++ [:delivery, :total],
            event_name: delivery_event(),
            description: "Число попыток доставки записей outbox",
            tags: [:outcome, :topic],
            tag_values: &delivery_tag_values/1
          ),
          counter(
            metric_prefix ++ [:cleaner, :cycles, :total],
            event_name: cleaner_cycle_event(),
            description: "Число циклов outbox cleaner",
            tags: [:result],
            tag_values: &result_tag_values/1
          ),
          distribution(
            metric_prefix ++ [:cleaner, :duration, duration_unit_plural],
            event_name: cleaner_cycle_event(),
            measurement: :duration,
            description: "Длительность цикла outbox cleaner",
            reporter_options: [buckets: @duration_buckets],
            tags: [:result],
            tag_values: &result_tag_values/1,
            unit: {:native, duration_unit}
          ),
          sum(
            metric_prefix ++ [:cleaner, :deleted, :total],
            event_name: cleaner_cycle_event(),
            measurement: :deleted,
            description: "Число удалённых published-записей outbox",
            tags: [:result],
            tag_values: &result_tag_values/1
          )
        ]
      )
    ]
  end

  @doc false
  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :outbox))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      Polling.build(
        :outbox_queue_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_queue_metrics, []},
        [
          last_value(
            metric_prefix ++ [:queue, :count],
            event_name: @queue_count_event,
            description: "Число записей outbox по статусу",
            measurement: :count,
            tags: [:status]
          ),
          last_value(
            metric_prefix ++ [:queue, :oldest_age, :seconds],
            event_name: @oldest_age_event,
            description: "Возраст самой старой записи status=new (секунды)",
            measurement: :seconds
          ),
          last_value(
            metric_prefix ++ [:queue, :expired_locks, :count],
            event_name: @expired_locks_event,
            description: "Число in_work с истёкшим locked_until",
            measurement: :count
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc false
  @spec execute_queue_metrics() :: :ok

  def execute_queue_metrics do
    Safe.execute("outbox queue", &emit_queue_metrics/0)
  end

  # ---

  defp emit_queue_metrics do
    repo = repo()

    repo.counts_by_status()
    |> Enum.each(fn {status, count} ->
      :telemetry.execute(
        @queue_count_event,
        %{count: count},
        %{status: Atom.to_string(status)}
      )
    end)

    :telemetry.execute(
      @oldest_age_event,
      %{seconds: repo.oldest_age_seconds(:new) || 0},
      %{}
    )

    :telemetry.execute(
      @expired_locks_event,
      %{count: repo.expired_lock_count()},
      %{}
    )
  end

  # Реализация берётся из DI, а не прибивается к Pg: метрики читают ту же очередь,
  # что и поллер.
  defp repo, do: Application.fetch_env!(:core, Outbox.Repo)

  defp result_tag_values(%{result: result}) do
    %{result: to_string(result)}
  end

  defp delivery_tag_values(%{outcome: outcome, topic: topic}) do
    %{outcome: to_string(outcome), topic: topic}
  end

  # ---
  # Имена событий резолвятся в рантайме: префикс задаёт потребитель
  # (`Core.Config.telemetry_prefix/0`), а библиотека компилируется один раз на все приложения.

  defp poller_cycle_event, do: Telemetry.event([:outbox, :poller, :cycle])

  defp delivery_event, do: Telemetry.event([:outbox, :delivery])

  defp cleaner_cycle_event, do: Telemetry.event([:outbox, :cleaner, :cycle])
end
