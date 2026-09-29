defmodule Core.Mq.PromEx do
  @moduledoc """
  PromEx plugin метрик MQ.

  Event-метрики: publish в RabbitMQ Stream и в Kafka, deliver и decode_drop stream
  reader'а, циклы и выбросы в DLQ reliable-подписчика. Polling-метрики: длина буфера,
  остаток текущего чанка, pending и наличие подписки у наблюдаемых reader'ов.

  Опция `readers:` — MFA-провайдер списка наблюдаемых stream reader'ов
  (`{MyApp.PromEx.Mq, :readers, []}` → `[%{component: String.t(), name: atom()}]`),
  как `watch:` у `Core.Workers.PromEx`: список процессов принадлежит рантайму
  потребителя, а не моменту сборки метрик (`10-architecture.md`). Без опции
  polling-группа не строится.

  Reader'ы с одной парой `component` и `topic` сводятся в одно значение: `subscribed` — минимум,
  `pending` — максимум, `buffer_len` и `chunk_remaining` — сумма; повтор — `error` в лог
  (`Core.PromEx.Labels`). Топик reader'а известен только живому процессу, поэтому сводятся только
  живые: упавший reader этими метриками не виден — его видит `up` плагина `Core.Workers.PromEx`.
  """

  use PromEx.Plugin

  alias Core.Mq.Stream.Reader
  alias Core.PromEx.Labels
  alias Core.PromEx.Safe
  alias Core.Telemetry

  @buffer_len_event [:prom_ex, :plugin, :mq, :reader, :buffer_len]
  @chunk_remaining_event [:prom_ex, :plugin, :mq, :reader, :chunk_remaining]
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
          ),
          Safe.error_metric(metric_prefix, :mq)
        ]
      )
    ]
  end

  @doc false
  @impl true
  def polling_metrics(opts) do
    case Keyword.get(opts, :readers) do
      nil ->
        []

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        [
          reader_poll_group(opts, {mod, fun, args})
        ]
    end
  end

  # Два уровня `Safe` делают разное: внешний `execute/4` ловит сбой самого провайдера
  # (список reader'ов не собрался — цикл пропускается целиком), внутренний `collect/4` —
  # недоступность одного reader'а, чтобы она не уносила метрики остальных.
  @doc false
  @spec execute_reader_metrics({module(), atom(), [term()]}) :: :ok

  def execute_reader_metrics({mod, fun, args}) when is_atom(mod) and is_atom(fun) do
    Safe.execute(:mq, :readers, "mq readers", fn ->
      groups =
        mod
        |> apply(fun, args)
        |> Enum.flat_map(&reader_sample/1)
        |> Labels.group(&{&1.component, &1.topic})

      Labels.report("mq_readers mfa=#{inspect({mod, fun, args})}", groups)
      Enum.each(groups, &emit_reader_group/1)
    end)
  end

  # ---

  defp reader_poll_group(opts, readers) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :mq))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

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
          metric_prefix ++ [:reader, :chunk_remaining],
          event_name: @chunk_remaining_event,
          description: "Записей осталось в текущем чанке stream reader",
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
  end

  defp reader_sample(%{component: component, name: name}) do
    Safe.collect(:mq, :readers, "mq reader #{component}", fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> [sample(component, name, Reader.info(pid))]
        nil -> []
      end
    end)
  end

  defp sample(component, name, info) do
    %{
      component: component,
      name: name,
      topic: info.topic,
      buffer_len: info.buffer_len,
      chunk_remaining: info.chunk_remaining,
      pending: flag(info.pending?),
      subscribed: flag(info.subscribed?)
    }
  end

  defp flag(true), do: 1
  defp flag(false), do: 0

  defp emit_reader_group({{component, topic}, samples}) do
    meta = %{component: component, topic: topic}

    :telemetry.execute(@buffer_len_event, %{value: Enum.sum(values(samples, :buffer_len))}, meta)
    :telemetry.execute(@chunk_remaining_event, %{value: Enum.sum(values(samples, :chunk_remaining))}, meta)
    :telemetry.execute(@pending_event, %{value: Enum.max(values(samples, :pending))}, meta)
    :telemetry.execute(@subscribed_event, %{value: Enum.min(values(samples, :subscribed))}, meta)
  end

  defp values(samples, key), do: Enum.map(samples, &Map.fetch!(&1, key))

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

  # Имена событий резолвятся в рантайме: префикс задаёт потребитель
  # (`Core.Config.telemetry_prefix/0`), а библиотека компилируется один раз на все приложения.

  defp publish_event, do: Telemetry.event([:mq, :stream, :publish])

  defp deliver_event, do: Telemetry.event([:mq, :stream, :deliver])

  defp decode_drop_event, do: Telemetry.event([:mq, :stream, :decode_drop])

  defp kafka_publish_event, do: Telemetry.event([:mq, :kafka, :publish])

  defp subscriber_cycle_event, do: Telemetry.event([:mq, :subscriber, :cycle])

  defp subscriber_dlq_event, do: Telemetry.event([:mq, :subscriber, :dlq])
end
