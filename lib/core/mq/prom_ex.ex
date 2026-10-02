defmodule Core.Mq.PromEx do
  @moduledoc """
  PromEx plugin метрик MQ.

  Event-метрики: publish в RabbitMQ Stream и в Kafka, deliver и decode_drop stream
  reader'а, циклы и выбросы в DLQ reliable-подписчика. Polling-метрики: длина буфера,
  остаток текущего чанка, pending и наличие подписки у наблюдаемых reader'ов.

  Опция `readers:` — MFA-провайдер списка наблюдаемых stream reader'ов
  (`{MyAppApp.PromEx.Mq, :readers, []}` → `[%{component: String.t(), name: atom()}]`),
  как `watch:` у `Core.Workers.PromEx`: список процессов принадлежит рантайму
  потребителя, а не моменту сборки метрик (`10-architecture.md`). Без опции
  polling-группа не строится.

  Reader'ы с одной парой `component` и `topic` сводятся в одно значение: `subscribed` — минимум,
  `pending` — максимум, `buffer_len` и `chunk_remaining` — сумма; повтор — `error` в лог
  (`Core.PromEx.Labels`). Топик reader'а известен только живому процессу, поэтому сводятся только
  живые: упавший reader этими метриками не виден — его видит `up` плагина `Core.Workers.PromEx`.

  Чтение Kafka (`Core.Mq.Kafka.Reader`): event-счётчики `kafka_offset_reset_total{topic}`,
  `kafka_decode_drop_total{topic}`, `kafka_read_errors_total{topic, reason}` и
  `kafka_commit_errors_total{topic, reason}` — `sum` по `count`, серии засевает читатель при
  старте. Опция `kafka_readers:` — MFA-провайдер читателей Kafka в той же форме, что `readers:`
  (`Core.PubSub.MqSubscriberReliable.Supervisor.kafka_readers/1`); без неё группа не строится.
  Gauge'и группы: `kafka_reader_lease{component, topic}` (0|1) и по партиции
  `kafka_reader_lag_messages` — `high_wm_offset` последней пачки минус зафиксированное смещение —
  и `kafka_reader_lag_seconds` — сейчас минус `ts` последнего закоммиченного сообщения. Отставание
  снимает только владелец аренды; нода без неё отдаёт нули по партициям, которые читала:
  агрегировать — `max`. Неизвестное значение (до первой пачки, до первого `commit` на ноде) точки
  не даёт. Упавший читатель, как и stream reader, этими метриками не виден — его видит `up`
  плагина `Core.Workers.PromEx`. На пустом топике `lag_seconds` растёт без отставания — смотреть вместе с
  `lag_messages` (`21-observability.md`, «Отставание чтения Kafka»).

  Опция `dlq_repo:` — Ecto-репозиторий с таблицей `Core.Mq.Dlq.Migration`: gauge `dlq_count` —
  число записей DLQ в Postgres по `subscriber`, `topic` и `status` (`dead` / `requeued` /
  `processed`, `Core.Mq.Dlq.counts/1`). Без опции группа не строится. Каждая нода считает одну
  таблицу: агрегировать — `max`, а не `sum`.
  """

  use PromEx.Plugin

  alias Core.Mq.Dlq
  alias Core.Mq.Kafka
  alias Core.Mq.Stream.Reader
  alias Core.PromEx.Labels
  alias Core.PromEx.Safe
  alias Core.Telemetry

  @buffer_len_event [:prom_ex, :plugin, :mq, :reader, :buffer_len]
  @chunk_remaining_event [:prom_ex, :plugin, :mq, :reader, :chunk_remaining]
  @pending_event [:prom_ex, :plugin, :mq, :reader, :pending]
  @subscribed_event [:prom_ex, :plugin, :mq, :reader, :subscribed]
  @dlq_count_event [:prom_ex, :plugin, :mq, :dlq, :count]
  @kafka_lease_event [:prom_ex, :plugin, :mq, :kafka_reader, :lease]
  @kafka_lag_messages_event [:prom_ex, :plugin, :mq, :kafka_reader, :lag_messages]
  @kafka_lag_seconds_event [:prom_ex, :plugin, :mq, :kafka_reader, :lag_seconds]

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
            description:
              "Число сообщений, отправленных подписчиком в DLQ: rejected — отказ обработчика, " <>
                "exhausted — исчерпание попыток",
            tags: [:topic, :dlq_topic, :reason],
            tag_values: &dlq_tag_values/1
          ),
          sum(
            metric_prefix ++ [:kafka, :offset_reset, :total],
            event_name: kafka_event(:offset_reset),
            measurement: :count,
            description: "Число сбросов смещения читателя Kafka на earliest: смещение вне лога",
            tags: [:topic]
          ),
          sum(
            metric_prefix ++ [:kafka, :decode_drop, :total],
            event_name: kafka_event(:decode_drop),
            measurement: :count,
            description: "Число записей Kafka, пропущенных читателем: их не принимает Mq.Message",
            tags: [:topic]
          ),
          sum(
            metric_prefix ++ [:kafka, :read_errors, :total],
            event_name: kafka_event(:read_error),
            measurement: :count,
            description:
              "Число отказов чтения Kafka: subscribe — подписка на партиции, consumer_down — падение " <>
                "консьюмера партиции, lease — продление аренды",
            tags: [:topic, :reason],
            tag_values: &reason_tag_values/1
          ),
          sum(
            metric_prefix ++ [:kafka, :commit_errors, :total],
            event_name: kafka_event(:commit_error),
            measurement: :count,
            description:
              "Число отказов commit читателя Kafka: lease_lost — аренда потеряна, failed — смещение не записано",
            tags: [:topic, :reason],
            tag_values: &reason_tag_values/1
          ),
          Safe.error_metric(metric_prefix, :mq)
        ]
      )
    ]
  end

  @doc false
  @impl true
  def polling_metrics(opts) do
    reader_groups(opts, Keyword.get(opts, :readers)) ++
      kafka_reader_groups(opts, Keyword.get(opts, :kafka_readers)) ++
      dlq_groups(opts, Keyword.get(opts, :dlq_repo))
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

  @doc false
  @spec execute_kafka_reader_metrics({module(), atom(), [term()]}) :: :ok

  def execute_kafka_reader_metrics({mod, fun, args}) when is_atom(mod) and is_atom(fun) do
    Safe.execute(:mq, :kafka_readers, "mq kafka readers", fn ->
      now = System.os_time(:millisecond)

      groups =
        mod
        |> apply(fun, args)
        |> Enum.flat_map(&kafka_reader_sample(&1, now))
        |> Labels.group(&{&1.component, &1.topic})

      Labels.report("mq_kafka_readers mfa=#{inspect({mod, fun, args})}", groups)
      Enum.each(groups, &emit_kafka_reader_group/1)
    end)
  end

  @doc false
  @spec execute_dlq_metrics(module()) :: :ok

  def execute_dlq_metrics(repo) when is_atom(repo) do
    Safe.execute(:mq, :dlq, "mq dlq", fn ->
      Enum.each(Dlq.counts(repo), fn %{count: count} = row ->
        :telemetry.execute(@dlq_count_event, %{value: count}, Map.delete(row, :count))
      end)
    end)
  end

  # ---

  defp reader_groups(_opts, nil), do: []

  defp reader_groups(opts, {mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args),
    do: [reader_poll_group(opts, {mod, fun, args})]

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

  defp kafka_reader_groups(_opts, nil), do: []

  defp kafka_reader_groups(opts, {mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :mq))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      Polling.build(
        :mq_kafka_reader_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_kafka_reader_metrics, [{mod, fun, args}]},
        [
          last_value(
            metric_prefix ++ [:kafka_reader, :lease],
            event_name: @kafka_lease_event,
            description: "Держит ли нода аренду топика читателя Kafka (0|1)",
            measurement: :value,
            tags: [:component, :topic],
            tag_values: &reader_tag_values/1
          ),
          last_value(
            metric_prefix ++ [:kafka_reader, :lag_messages],
            event_name: @kafka_lag_messages_event,
            description:
              "Отставание чтения Kafka в сообщениях: high_wm_offset последней пачки минус зафиксированное " <>
                "смещение; у ноды без аренды — 0",
            measurement: :value,
            tags: [:component, :topic, :partition],
            tag_values: &partition_tag_values/1
          ),
          last_value(
            metric_prefix ++ [:kafka_reader, :lag_seconds],
            event_name: @kafka_lag_seconds_event,
            description:
              "Отставание чтения Kafka по времени: сейчас минус timestamp последнего закоммиченного " <>
                "сообщения; у ноды без аренды — 0",
            measurement: :value,
            tags: [:component, :topic, :partition],
            tag_values: &partition_tag_values/1
          )
        ],
        detach_on_error: false
      )
    ]
  end

  defp kafka_reader_sample(%{component: component, name: name}, now) do
    Safe.collect(:mq, :kafka_readers, "mq kafka reader #{component}", fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> [kafka_sample(component, name, Kafka.Reader.info(pid), now)]
        nil -> []
      end
    end)
  end

  # Отставание снимает только владелец аренды (ADR-0033). Нода без неё отдаёт нули по известным
  # партициям: `last_value` держал бы значение, снятое при потере аренды, и `max` по нодам видел бы
  # отставание, которое уже разгребает новый владелец.
  defp kafka_sample(component, name, %{lease?: lease?, topic: topic, partitions: partitions}, now) do
    %{
      component: component,
      name: name,
      topic: topic,
      lease: flag(lease?),
      lags: Map.new(partitions, fn {partition, info} -> {partition, lags(lease?, info, now)} end)
    }
  end

  defp lags(false, _info, _now), do: %{messages: 0, seconds: 0}

  defp lags(true, info, now), do: %{messages: lag_messages(info), seconds: lag_seconds(info, now)}

  defp lag_messages(%{high_wm_offset: high_wm, committed_offset: committed})
       when is_integer(high_wm) and is_integer(committed),
       do: high_wm - committed

  defp lag_messages(_info), do: nil

  defp lag_seconds(%{committed_ts: ts}, now) when is_integer(ts), do: (now - ts) / 1_000

  defp lag_seconds(_info, _now), do: nil

  defp emit_kafka_reader_group({{component, topic}, samples}) do
    meta = %{component: component, topic: topic}

    :telemetry.execute(@kafka_lease_event, %{value: Enum.max(values(samples, :lease))}, meta)

    samples
    |> Enum.flat_map(&Map.to_list(&1.lags))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {partition, lags} ->
      meta = Map.put(meta, :partition, partition)
      emit_lag(@kafka_lag_messages_event, Enum.map(lags, & &1.messages), meta)
      emit_lag(@kafka_lag_seconds_event, Enum.map(lags, & &1.seconds), meta)
    end)
  end

  # Значение неизвестно — точки нет: до первой пачки нет `high_wm_offset`, до первого `commit` —
  # `ts`, а без сохранённого смещения — и зафиксированного смещения.
  defp emit_lag(event, lags, meta) do
    case Enum.reject(lags, &is_nil/1) do
      [] -> :ok
      known -> :telemetry.execute(event, %{value: Enum.max(known)}, meta)
    end
  end

  defp dlq_groups(_opts, nil), do: []

  defp dlq_groups(opts, repo) when is_atom(repo) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :mq))
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      Polling.build(
        :mq_dlq_poll_metrics,
        poll_rate,
        {__MODULE__, :execute_dlq_metrics, [repo]},
        [
          last_value(
            metric_prefix ++ [:dlq, :count],
            event_name: @dlq_count_event,
            description: "Число записей DLQ в Postgres по подписчику, топику и статусу",
            measurement: :value,
            tags: [:subscriber, :topic, :status]
          )
        ],
        detach_on_error: false
      )
    ]
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

  defp dlq_tag_values(%{topic: topic, dlq_topic: dlq_topic, reason: reason}) do
    %{topic: topic, dlq_topic: dlq_topic, reason: to_string(reason)}
  end

  defp reader_tag_values(%{component: component, topic: topic}) do
    %{component: component, topic: topic}
  end

  defp partition_tag_values(%{component: component, topic: topic, partition: partition}) do
    %{component: component, topic: topic, partition: Integer.to_string(partition)}
  end

  defp reason_tag_values(%{topic: topic, reason: reason}) do
    %{topic: topic, reason: to_string(reason)}
  end

  # Имена событий резолвятся в рантайме: префикс задаёт потребитель
  # (`Core.Config.telemetry_prefix/0`), а библиотека компилируется один раз на все приложения.

  defp publish_event, do: Telemetry.event([:mq, :stream, :publish])

  defp deliver_event, do: Telemetry.event([:mq, :stream, :deliver])

  defp decode_drop_event, do: Telemetry.event([:mq, :stream, :decode_drop])

  defp kafka_publish_event, do: Telemetry.event([:mq, :kafka, :publish])

  defp subscriber_cycle_event, do: Telemetry.event([:mq, :subscriber, :cycle])

  defp subscriber_dlq_event, do: Telemetry.event([:mq, :subscriber, :dlq])

  defp kafka_event(name), do: Telemetry.event([:mq, :kafka, name])
end
