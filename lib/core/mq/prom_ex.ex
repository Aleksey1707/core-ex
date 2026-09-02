defmodule Core.Mq.PromEx do
  @moduledoc """
  PromEx plugin: event-метрики MQ Stream publish/deliver и polling buffer reader.

  Опция `readers:` — список наблюдаемых stream reader'ов
  (`[%{component: String.t(), name: atom()}]`), default `[]`.
  """

  use PromEx.Plugin

  alias Core.Mq.Stream.Reader
  alias Core.PromEx.Safe
  alias Core.Telemetry

  @buffer_len_event [:prom_ex, :plugin, :mq, :reader, :buffer_len]
  @pending_event [:prom_ex, :plugin, :mq, :reader, :pending]
  @subscribed_event [:prom_ex, :plugin, :mq, :reader, :subscribed]

  @duration_buckets [1, 10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @doc false
  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :mq))
    duration_unit = Keyword.get(opts, :duration_unit, :millisecond)
    duration_unit_plural = PromEx.Utils.make_plural_atom(duration_unit)

    [
      Event.build(
        :mq_event_metrics,
        [
          counter(
            metric_prefix ++ [:publish, :total],
            event_name: publish_event(),
            description: "Число publish в RabbitMQ Stream",
            tags: [:result, :topic],
            tag_values: &publish_tag_values/1
          ),
          distribution(
            metric_prefix ++ [:publish, :duration, duration_unit_plural],
            event_name: publish_event(),
            measurement: :duration,
            description: "Длительность publish в RabbitMQ Stream",
            reporter_options: [buckets: @duration_buckets],
            tags: [:result, :topic],
            tag_values: &publish_tag_values/1,
            unit: {:native, duration_unit}
          ),
          counter(
            metric_prefix ++ [:kafka, :publish, :total],
            event_name: kafka_publish_event(),
            description: "Число publish в Kafka",
            tags: [:result, :topic],
            tag_values: &publish_tag_values/1
          ),
          distribution(
            metric_prefix ++ [:kafka, :publish, :duration, duration_unit_plural],
            event_name: kafka_publish_event(),
            measurement: :duration,
            description: "Длительность publish в Kafka",
            reporter_options: [buckets: @duration_buckets],
            tags: [:result, :topic],
            tag_values: &publish_tag_values/1,
            unit: {:native, duration_unit}
          ),
          sum(
            metric_prefix ++ [:deliver, :entries, :total],
            event_name: deliver_event(),
            measurement: :entries,
            description: "Число entries, доставленных stream reader",
            tags: [:topic],
            tag_values: &topic_tag_values/1
          ),
          counter(
            metric_prefix ++ [:decode_drop, :total],
            event_name: decode_drop_event(),
            description: "Число отброшенных при decode stream entries",
            tags: [:topic],
            tag_values: &topic_tag_values/1
          ),
          counter(
            metric_prefix ++ [:subscriber, :cycles, :total],
            event_name: subscriber_cycle_event(),
            description: "Число циклов reliable MQ subscriber",
            tags: [:result, :topic],
            tag_values: &subscriber_tag_values/1
          ),
          counter(
            metric_prefix ++ [:subscriber, :dlq, :total],
            event_name: subscriber_dlq_event(),
            description: "Число сообщений, отправленных подписчиком в DLQ",
            tags: [:topic, :dlq_topic],
            tag_values: &dlq_tag_values/1
          )
        ]
      )
    ]
  end

  @doc false
  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :mq))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)
    readers = Keyword.get(opts, :readers, [])

    [
      Polling.build(
        :mq_reader_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_reader_metrics, [readers]},
        [
          last_value(
            metric_prefix ++ [:reader, :buffer_len],
            event_name: @buffer_len_event,
            description: "Размер буфера stream reader",
            measurement: :value,
            tags: [:component, :topic],
            tag_values: &reader_tag_values/1
          ),
          last_value(
            metric_prefix ++ [:reader, :pending],
            event_name: @pending_event,
            description: "Есть ли pending-сообщение у stream reader (0|1)",
            measurement: :value,
            tags: [:component, :topic],
            tag_values: &reader_tag_values/1
          ),
          last_value(
            metric_prefix ++ [:reader, :subscribed],
            event_name: @subscribed_event,
            description: "Установлена ли подписка stream reader (0|1)",
            measurement: :value,
            tags: [:component, :topic],
            tag_values: &reader_tag_values/1
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc false
  @spec execute_reader_metrics([map()]) :: :ok

  def execute_reader_metrics(readers) when is_list(readers) do
    Enum.each(readers, &emit_reader_metrics/1)
  end

  # ---

  defp emit_reader_metrics(%{component: component, name: name}) do
    Safe.execute("mq reader #{component}", fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> emit_reader_info(component, Reader.info(pid))
        nil -> :ok
      end
    end)
  end

  defp emit_reader_info(component, info) do
    meta = %{component: component, topic: info.topic}
    pending = if info.pending?, do: 1, else: 0
    subscribed = if info.subscribed?, do: 1, else: 0

    :telemetry.execute(@buffer_len_event, %{value: info.buffer_len}, meta)
    :telemetry.execute(@pending_event, %{value: pending}, meta)
    :telemetry.execute(@subscribed_event, %{value: subscribed}, meta)
  end

  defp publish_tag_values(%{result: result, topic: topic}) do
    %{result: to_string(result), topic: topic}
  end

  defp topic_tag_values(%{topic: topic}) do
    %{topic: topic}
  end

  defp subscriber_tag_values(%{result: result, topic: topic}) do
    %{result: to_string(result), topic: topic}
  end

  defp dlq_tag_values(%{topic: topic, dlq_topic: dlq_topic}) do
    %{topic: topic, dlq_topic: dlq_topic}
  end

  defp reader_tag_values(%{component: component, topic: topic}) do
    %{component: component, topic: topic}
  end

  # ---
  # Имена событий резолвятся в рантайме: префикс задаёт потребитель
  # (`Core.Config.telemetry_prefix/0`), а библиотека компилируется один раз на все приложения.

  defp publish_event, do: Telemetry.event([:mq, :stream, :publish])

  defp deliver_event, do: Telemetry.event([:mq, :stream, :deliver])

  defp decode_drop_event, do: Telemetry.event([:mq, :stream, :decode_drop])

  defp kafka_publish_event, do: Telemetry.event([:mq, :kafka, :publish])

  defp subscriber_cycle_event, do: Telemetry.event([:mq, :subscriber, :cycle])

  defp subscriber_dlq_event, do: Telemetry.event([:mq, :subscriber, :dlq])
end
