# Kafka-клиент объявлен в библиотеке `optional: true`: адаптер компилируется только
# у тех потребителей, которые добавили клиента себе в `deps`. Без него модуля
# просто нет — вместо ошибки компиляции библиотеки вызов даст UndefinedFunctionError.
if Code.ensure_loaded?(:brod) do
  defmodule Core.Mq.Kafka.Reader do
    @moduledoc """
    `Mq.ReaderReliable` для Kafka через клиент `:brod`, без consumer group (ADR-0033).

    Читатель — подписчик `brod_consumer` каждой партиции топика (`:brod.subscribe/5`): пачки
    `#kafka_message_set{}` приходят ему в почтовый ящик и копятся в буфере по партициям. `get`
    обходит партиции по кругу; в работе — одно сообщение на читатель, и `get` без `commit`
    отдаёт его же. Буфер партиции ограничен `prefetch_count`: `brod_consumer` не запрашивает
    следующую пачку, пока неподтверждённых больше (`prefetch_bytes: 0`), а подтверждение
    (`consume_ack`) идёт только за `commit`. Граница мягкая: последняя запрошенная пачка
    приходит целиком, до `max_bytes` консьюмера (1 МБ по умолчанию).

    Последовательность — внутри партиции, между партициями порядка нет. Сообщение, которое
    подписчик повторяет, держит **весь** топик (head-of-line): пока оно в работе, `get` не
    отдаёт ничего другого, в том числе из соседних партиций.

    ## Смещения и аренда

    Следующее смещение партиции — строка таблицы БД потребителя
    (`Core.Mq.Kafka.Migration`, `Core.Mq.Kafka.Reader.Store`), ключ `(subscriber_name, topic,
    partition)`. `commit` — синхронная запись, `:ok` значит «записано», затем `consume_ack`.
    Гарантия — at-least-once.

    Топик читает одна нода — владелец аренды строкой с fencing-токеном. Нода без аренды не
    подписана и отдаёт `:empty`, пробуя взять аренду раз в треть `lease_ttl_ms`. `commit`
    устаревшей ноды — `{:error, %Error{code: :kafka_lease_lost}}`, сообщение повторит новый
    владелец. Потеря аренды — отписка от партиций, сброс буфера и сообщения в работе. Штатная
    остановка отдаёт аренду сразу.

    ## Сбои

    - Без сохранённого смещения партиция читается со стартовой позиции `initial_offset`
      (`:earliest` — с начала топика, по умолчанию).
    - Смещение вне лога (`OFFSET_OUT_OF_RANGE`: его съела retention, топик пересоздан) —
      `error` в лог, событие `[:core, :mq, :kafka, :offset_reset]` и переподписка с earliest.
    - Смену лидера `brod_consumer` обрабатывает сам. Его перезапуск читатель видит по monitor:
      буфер и сообщение в работе этой партиции сбрасываются, переподписка — с зафиксированного
      смещения с backoff от `retry_min_ms` до `retry_max_ms`; `warning` — раз на попытку.
    - Неизвестный топик — `error` в лог с тем же backoff, читатель жив и отдаёт `:empty`.
    - Число партиций перечитывается раз в `partitions_interval_ms`. Консьюмеры партиций
      `:brod` заводит при старте топика, поэтому выросший топик перезапускается целиком
      (`:brod_client.stop_consumer/2`), и чтение всех партиций продолжается с зафиксированных смещений.

    ## Опции

    Обязательные: `client:` (id клиента `:brod`, как handle `Kafka.Writer`), `topic:`
    (`Mq.Topic`), `subscriber_name:` (`Mq.SubscriberName`), `repo:` (Ecto-репозиторий с
    таблицами `Core.Mq.Kafka.Migration`). Необязательные: `initial_offset:` (`:earliest` |
    `:latest`), `prefetch_count:` (default 10), `lease_ttl_ms:` (default 30 000),
    `partitions_interval_ms:` (default 60 000), `retry_min_ms:`, `retry_max_ms:`, `name:`,
    `shutdown:`.

    Консьюмер партиции у `:brod` принимает одного подписчика: читатели одного топика с разными
    `subscriber_name` требуют разных клиентов.

    ## Wire-формат

    Запись Kafka без конверта (ADR-0004): значение — `body`, ключ — `Mq.Key`, заголовки —
    `headers` (имя в lowercase, при повторе — последнее значение), партиция и смещение —
    `position`. `:brod` не различает null и пустые байты: пустое значение приходит как `nil`
    (tombstone), пустой ключ — как `key: nil` (ADR-0032). Запись, которую `Mq.Message` не
    принимает (имя заголовка пустое или не в UTF-8), — `error` в лог, событие
    `[:core, :mq, :kafka, :decode_drop]` и запись её смещения: повтор дал бы тот же отказ.

    `info/1` отдаёт по партиции `high_wm_offset` последней пачки, зафиксированное смещение и
    `ts` последнего закоммиченного сообщения — для метрик отставания.
    """

    @behaviour Core.Mq.ReaderReliable

    use GenServer

    alias Core.Error
    alias Core.Helper.StartOpts
    alias Core.Mq
    alias Core.Mq.Kafka.Reader.Store
    alias Core.Mq.Message
    alias Core.Telemetry

    require Error
    require Logger
    require Record

    Record.defrecordp(
      :kafka_message,
      Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
    )

    Record.defrecordp(:kafka_message_set, Record.extract(:kafka_message_set, from_lib: "brod/include/brod.hrl"))
    Record.defrecordp(:kafka_fetch_error, Record.extract(:kafka_fetch_error, from_lib: "brod/include/brod.hrl"))

    @label "Mq.Kafka.Reader"
    @shutdown_ms 15_000
    # `commit` и пропуск нечитаемой записи в `get` пишут в базу: запас на таймаут запроса Ecto.
    @call_timeout 20_000
    @prefetch_count 10
    @lease_ttl_ms 30_000
    @partitions_interval_ms 60_000
    @retry_min_ms 1_000
    @retry_max_ms 30_000
    @initial_offsets ~w(earliest latest)a

    defstruct [
      :client,
      :topic,
      :topic_name,
      :subscriber,
      :repo,
      :initial_offset,
      :prefetch_count,
      :lease_ttl_ms,
      :partitions_interval_ms,
      :retry_min_ms,
      :retry_max_ms,
      :retry_ms,
      lease: nil,
      lease_deadline: nil,
      partition_count: nil,
      partitions: %{},
      next_partition: 0,
      pending: nil,
      stats: %{},
      resubscribe_timer: nil
    ]

    @type t :: GenServer.server()

    @typedoc "Состояние партиции для метрик: смещения и `ts` — `nil`, пока их не было."
    @type partition_info :: %{
            high_wm_offset: integer() | nil,
            committed_offset: non_neg_integer() | nil,
            committed_ts: integer() | nil,
            buffered: non_neg_integer()
          }

    @doc """
    Спецификация ребёнка супервизора.

    `:shutdown` (default #{@shutdown_ms} мс) — запас на `terminate/2`: читатель отписывается от
    консьюмеров и отдаёт аренду, иначе следующая нода ждёт её истечения.
    """
    @spec child_spec(keyword()) :: Supervisor.child_spec()

    def child_spec(opts) when is_list(opts) do
      %{
        id: StartOpts.name!(@label, opts, :name) || __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        shutdown: StartOpts.shutdown!(@label, opts, :shutdown, @shutdown_ms)
      }
    end

    @doc "Запустить читатель."
    @spec start_link(keyword()) :: GenServer.on_start()

    def start_link(opts) when is_list(opts) do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    end

    @doc "Прочитать следующее сообщение; `timeout` — сколько ждать его появления."
    @spec get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}

    @impl true
    def get(server, timeout \\ 0)

    def get(server, 0), do: GenServer.call(server, :get, @call_timeout)

    def get(server, timeout) when timeout == :infinity or (is_integer(timeout) and timeout > 0),
      do: poll(server, deadline(timeout))

    @doc "Зафиксировать смещение сообщения в работе."
    @spec commit(t()) :: :ok | {:error, Error.t()}

    @impl true
    def commit(server), do: GenServer.call(server, :commit, @call_timeout)

    @doc "Аренда, сообщение в работе и состояние партиций (для метрик и разбора)."
    @spec info(t()) :: %{
            lease?: boolean(),
            pending?: boolean(),
            topic: String.t(),
            partitions: %{non_neg_integer() => partition_info()}
          }

    def info(server), do: GenServer.call(server, :info, @call_timeout)

    @doc false
    @impl true
    def init(opts) do
      # Подписки и аренда — внешние ресурсы: без trap_exit штатная остановка супервизором не
      # вызывает terminate/2, и следующая нода ждёт истечения аренды.
      Process.flag(:trap_exit, true)

      {:ok, build_state(opts), {:continue, :lease}}
    end

    @doc false
    @impl true
    def handle_continue(:lease, state) do
      Process.send_after(self(), :partitions, state.partitions_interval_ms)

      {:noreply, lease_tick(state)}
    end

    @doc false
    @impl true
    def handle_call(:get, _from, state) do
      if leased?(state),
        do: reply_get(take(state)),
        else: {:reply, :empty, state}
    end

    def handle_call(:commit, _from, %__MODULE__{pending: nil} = state) do
      {:reply, {:error, Error.app(code: :nothing_to_commit, ns: :mq, message: "Нет сообщения для commit")}, state}
    end

    def handle_call(:commit, _from, %__MODULE__{pending: pending} = state) do
      case commit_offset(state, pending.partition, pending.offset) do
        {:ok, state} -> {:reply, :ok, %{committed(state, pending) | pending: nil}}
        {:error, %Error{} = error, state} -> {:reply, {:error, error}, state}
      end
    end

    def handle_call(:info, _from, state) do
      info = %{
        lease?: leased?(state),
        pending?: not is_nil(state.pending),
        topic: state.topic_name,
        partitions:
          Map.new(state.stats, fn {partition, stats} -> {partition, partition_info(state, partition, stats)} end)
      }

      {:reply, info, state}
    end

    @doc false
    @impl true
    def handle_info(:lease, state), do: {:noreply, lease_tick(state)}

    def handle_info(:resubscribe, state) do
      state = %{state | resubscribe_timer: nil}

      if is_nil(state.lease),
        do: {:noreply, state},
        else: {:noreply, subscribe(state)}
    end

    def handle_info(:partitions, state) do
      Process.send_after(self(), :partitions, state.partitions_interval_ms)

      {:noreply, check_partitions(state)}
    end

    def handle_info({pid, kafka_message_set(partition: partition) = set}, state) when is_pid(pid) do
      case state.partitions do
        %{^partition => %{consumer: ^pid}} -> {:noreply, buffer(state, set)}
        _other -> {:noreply, state}
      end
    end

    def handle_info({pid, kafka_fetch_error(partition: partition, error_code: code)}, state) when is_pid(pid) do
      case state.partitions do
        %{^partition => %{consumer: ^pid}} -> {:noreply, fetch_error(state, partition, code)}
        _other -> {:noreply, state}
      end
    end

    def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
      case Enum.find(state.partitions, fn {_partition, %{ref: partition_ref}} -> partition_ref == ref end) do
        {partition, _} -> {:noreply, consumer_down(state, partition, reason)}
        nil -> {:noreply, state}
      end
    end

    def handle_info(_other, state), do: {:noreply, state}

    @doc false
    @impl true
    def terminate(_reason, %__MODULE__{lease: nil}), do: :ok

    def terminate(_reason, %__MODULE__{} = state) do
      _ = unsubscribe_all(state)
      _ = release(state)
      :ok
    end

    # ---

    defp build_state(opts) do
      retry_min_ms = StartOpts.pos_integer!(@label, opts, :retry_min_ms, @retry_min_ms)
      topic = StartOpts.prim!(@label, opts, :topic, Mq.Topic)

      %__MODULE__{
        client: StartOpts.atom!(@label, opts, :client),
        topic: topic,
        topic_name: Mq.Topic.value(topic),
        subscriber: Mq.SubscriberName.value(StartOpts.prim!(@label, opts, :subscriber_name, Mq.SubscriberName)),
        repo: StartOpts.module!(@label, opts, :repo),
        initial_offset: StartOpts.one_of!(@label, opts, :initial_offset, @initial_offsets, :earliest),
        prefetch_count: StartOpts.pos_integer!(@label, opts, :prefetch_count, @prefetch_count),
        lease_ttl_ms: StartOpts.pos_integer!(@label, opts, :lease_ttl_ms, @lease_ttl_ms),
        partitions_interval_ms: StartOpts.pos_integer!(@label, opts, :partitions_interval_ms, @partitions_interval_ms),
        retry_min_ms: retry_min_ms,
        retry_max_ms: StartOpts.pos_integer!(@label, opts, :retry_max_ms, @retry_max_ms),
        retry_ms: retry_min_ms
      }
    end

    defp reply_get({:ok, message, state}), do: {:reply, {:ok, message}, state}
    defp reply_get({:empty, state}), do: {:reply, :empty, state}
    defp reply_get({:error, %Error{} = error, state}), do: {:reply, {:error, error}, state}

    defp committed(state, pending) do
      stats = %{committed_offset: pending.offset + 1, committed_ts: pending.ts}

      %{state | stats: Map.update(state.stats, pending.partition, stats, &Map.merge(&1, stats))}
    end

    defp partition_info(state, partition, stats) do
      buffered =
        case state.partitions do
          %{^partition => %{buffer: buffer}} -> :queue.len(buffer)
          _other -> 0
        end

      %{
        high_wm_offset: Map.get(stats, :high_wm_offset),
        committed_offset: Map.get(stats, :committed_offset),
        committed_ts: Map.get(stats, :committed_ts),
        buffered: buffered
      }
    end

    defp poll(server, deadline) do
      case get(server, 0) do
        :empty -> idle_or_poll(server, deadline)
        other -> other
      end
    end

    defp idle_or_poll(server, deadline) do
      if timed_out?(deadline) do
        :empty
      else
        Process.sleep(10)
        poll(server, deadline)
      end
    end

    defp deadline(:infinity), do: :infinity
    defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

    defp timed_out?(:infinity), do: false
    defp timed_out?(deadline), do: System.monotonic_time(:millisecond) >= deadline

    # Срок считается от момента до запроса: Postgres продлевает аренду позже, и локальный срок
    # истекает не позже настоящего. Нода, которая не может продлить аренду (база недоступна),
    # перестаёт отдавать сообщения по нему, не дожидаясь ответа базы.
    defp lease_tick(state) do
      Process.send_after(self(), :lease, div(state.lease_ttl_ms, 3))

      hold_lease(state, System.monotonic_time(:millisecond))
    end

    defp leased?(%__MODULE__{lease: nil}), do: false

    defp leased?(%__MODULE__{lease_deadline: deadline}), do: System.monotonic_time(:millisecond) < deadline

    defp hold_lease(%__MODULE__{lease: nil} = state, started) do
      lease = Store.new_lease()

      case acquire(state, lease) do
        :ok ->
          Logger.info("kafka reader: аренда взята topic=#{state.topic_name} subscriber=#{state.subscriber}")
          subscribe(%{state | lease: lease, lease_deadline: started + state.lease_ttl_ms})

        :taken ->
          state

        {:error, reason} ->
          log_lease_failure(state, reason)
          state
      end
    end

    defp hold_lease(%__MODULE__{} = state, started) do
      case acquire(state, state.lease) do
        :ok ->
          %{state | lease_deadline: started + state.lease_ttl_ms}

        :taken ->
          Logger.warning("kafka reader: аренда перехвачена topic=#{state.topic_name} subscriber=#{state.subscriber}")
          lose_lease(state)

        {:error, reason} ->
          log_lease_failure(state, reason)
          if leased?(state), do: state, else: lose_lease(state)
      end
    end

    # Сбой базы — исключение `Ecto` (`Kafka.Reader.Store`): читатель от него не падает, аренда
    # просто не продлевается.
    defp acquire(state, lease) do
      Store.acquire(state.repo, state.subscriber, state.topic_name, lease, state.lease_ttl_ms)
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      :exit, reason -> {:error, reason}
    end

    defp release(state) do
      Store.release(state.repo, state.subscriber, state.topic_name, state.lease)
    rescue
      _exception -> :ok
    catch
      :exit, _reason -> :ok
    end

    defp log_lease_failure(state, reason) do
      Logger.warning(
        "kafka reader: аренда не продлена topic=#{state.topic_name} subscriber=#{state.subscriber} " <>
          "reason=#{inspect(reason)}"
      )
    end

    defp lose_lease(state) do
      state = unsubscribe_all(state)

      %{state | lease: nil, lease_deadline: nil, pending: nil}
    end

    # Подписываются партиции, у которых подписки нет: `:resubscribe` после сбоя части из них
    # доподписывает только недостающие, а смещения перечитываются из базы — они могли уйти
    # вперёд, пока партиция была без подписки.
    defp subscribe(state) do
      with {:ok, count} <- partitions_count(state),
           :ok <- start_consumer(state),
           {:ok, offsets} <- offsets(state) do
        state = %{state | partition_count: count}

        0..(count - 1)
        |> Enum.reject(&Map.has_key?(state.partitions, &1))
        |> Enum.reduce({state, []}, &subscribe_partition(&2, &1, Map.get(offsets, &1, state.initial_offset)))
        |> subscribed()
      else
        {:error, reason} -> schedule_resubscribe(state, reason)
      end
    end

    defp subscribed({state, []}), do: %{state | retry_ms: state.retry_min_ms}

    defp subscribed({state, failures}), do: schedule_resubscribe(state, failures)

    defp subscribe_partition({state, failures}, partition, begin_offset) do
      case brod_call(fn ->
             :brod.subscribe(state.client, self(), state.topic_name, partition, consumer_opts(state, begin_offset))
           end) do
        {:ok, pid} ->
          entry = %{consumer: pid, ref: Process.monitor(pid), buffer: :queue.new()}
          {%{state | partitions: Map.put(state.partitions, partition, entry)}, failures}

        {:error, reason} ->
          {state, [{partition, reason} | failures]}
      end
    end

    defp consumer_opts(state, begin_offset) do
      [
        begin_offset: begin_offset,
        prefetch_count: state.prefetch_count,
        prefetch_bytes: 0,
        offset_reset_policy: :reset_by_subscriber
      ]
    end

    defp partitions_count(state) do
      brod_call(fn -> :brod.get_partitions_count_safe(state.client, state.topic_name) end)
    end

    defp start_consumer(state) do
      brod_call(fn ->
        :brod.start_consumer(state.client, state.topic_name, consumer_opts(state, state.initial_offset))
      end)
    end

    defp offsets(state) do
      {:ok, Store.offsets(state.repo, state.subscriber, state.topic_name)}
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      :exit, reason -> {:error, reason}
    end

    # Одна попытка на backoff, сколько бы партиций ни упало разом: при падении клиента `DOWN`
    # приходит от каждого консьюмера, а `warning` — один.
    defp schedule_resubscribe(%__MODULE__{resubscribe_timer: timer} = state, _reason) when is_reference(timer),
      do: state

    defp schedule_resubscribe(state, reason) do
      Logger.log(
        log_level(reason),
        "kafka reader: переподписка topic=#{state.topic_name} subscriber=#{state.subscriber} " <>
          "reason=#{inspect(reason)} retry_in=#{state.retry_ms}ms"
      )

      timer = Process.send_after(self(), :resubscribe, state.retry_ms)

      %{state | resubscribe_timer: timer, retry_ms: min(state.retry_ms * 2, state.retry_max_ms)}
    end

    defp log_level(:unknown_topic_or_partition), do: :error
    defp log_level(_reason), do: :warning

    defp unsubscribe_all(state) do
      Enum.each(state.partitions, fn {_partition, entry} -> unsubscribe(entry) end)

      %{state | partitions: %{}}
    end

    # Отписка — синхронный вызов консьюмера: после ответа он пачек не шлёт, и то, что уже в
    # почтовом ящике, выбирается здесь, а не приходит новой подписке после её смещения.
    defp unsubscribe(%{consumer: pid, ref: ref}) do
      Process.demonitor(ref, [:flush])
      _ = brod_call(fn -> :brod.unsubscribe(pid, self()) end)
      flush(pid)
    end

    defp flush(pid) do
      receive do
        {^pid, _message} -> flush(pid)
      after
        0 -> :ok
      end
    end

    defp consumer_down(state, partition, reason) do
      state
      |> drop_partition(partition)
      |> schedule_resubscribe({:consumer_down, partition, reason})
    end

    defp drop_partition(state, partition) do
      {entry, partitions} = Map.pop!(state.partitions, partition)
      Process.demonitor(entry.ref, [:flush])
      flush(entry.consumer)

      %{state | partitions: partitions, pending: pending_without(state.pending, partition)}
    end

    defp pending_without(%{partition: partition}, partition), do: nil
    defp pending_without(pending, _partition), do: pending

    # Смещение вне лога: выбор — стоять до оператора или читать с начала. Для загрузки
    # справочников простой хуже громкого пропуска (ADR-0033), поэтому earliest.
    defp fetch_error(state, partition, :offset_out_of_range) do
      Logger.error(
        "kafka reader: смещение вне лога, партиция читается с начала: topic=#{state.topic_name} " <>
          "subscriber=#{state.subscriber} partition=#{partition}"
      )

      :telemetry.execute(
        Telemetry.event([:mq, :kafka, :offset_reset]),
        %{count: 1},
        %{topic: state.topic_name, partition: partition}
      )

      state = drop_partition(state, partition)
      {state, failures} = subscribe_partition({state, []}, partition, :earliest)
      subscribed_or_retry(state, failures)
    end

    # Прочие ошибки чтения `brod_consumer` разбирает сам: либо повторяет, либо завершается, и
    # читатель узнаёт об этом по monitor.
    defp fetch_error(state, _partition, _code), do: state

    defp subscribed_or_retry(state, []), do: state
    defp subscribed_or_retry(state, failures), do: schedule_resubscribe(state, failures)

    # Консьюмеры партиций `:brod` заводит при старте топика, новых сам не добавляет: выросший
    # топик перезапускается целиком. Кеш числа партиций клиент обновляет только для топиков
    # продюсеров, поэтому метаданные перечитываются явно.
    defp check_partitions(%__MODULE__{partition_count: count, lease: lease} = state)
         when is_integer(count) and not is_nil(lease) do
      _ = brod_call(fn -> :brod_client.get_metadata_safe(state.client, state.topic_name) end)

      case partitions_count(state) do
        {:ok, new_count} when new_count > count ->
          Logger.warning(
            "kafka reader: число партиций выросло, топик переподписывается: topic=#{state.topic_name} " <>
              "partitions=#{count}->#{new_count}"
          )

          state = %{unsubscribe_all(state) | pending: nil}
          _ = brod_call(fn -> :brod_client.stop_consumer(state.client, state.topic_name) end)
          subscribe(state)

        _other ->
          state
      end
    end

    defp check_partitions(state), do: state

    defp buffer(state, kafka_message_set(partition: partition, high_wm_offset: high_wm, messages: messages)) do
      stats = Map.update(state.stats, partition, %{high_wm_offset: high_wm}, &Map.put(&1, :high_wm_offset, high_wm))

      partitions =
        Map.update!(state.partitions, partition, fn entry ->
          %{entry | buffer: Enum.reduce(messages, entry.buffer, &:queue.in/2)}
        end)

      %{state | partitions: partitions, stats: stats}
    end

    defp take(%__MODULE__{pending: %{message: message}} = state), do: {:ok, message, state}

    defp take(state) do
      case next_record(state) do
        nil -> {:empty, state}
        {partition, record, popped} -> yield_or_drop(state, popped, partition, record)
      end
    end

    # Обход по кругу: поиск начинается с партиции, следующей за отданной последней.
    defp next_record(state) do
      {after_last, before_last} =
        state.partitions
        |> Map.keys()
        |> Enum.sort()
        |> Enum.split_with(&(&1 >= state.next_partition))

      Enum.find_value(after_last ++ before_last, &pop_record(state, &1))
    end

    defp pop_record(state, partition) do
      entry = Map.fetch!(state.partitions, partition)

      case :queue.out(entry.buffer) do
        {{:value, record}, buffer} ->
          partitions = Map.put(state.partitions, partition, %{entry | buffer: buffer})
          {partition, record, %{state | partitions: partitions, next_partition: partition + 1}}

        {:empty, _buffer} ->
          nil
      end
    end

    defp yield_or_drop(state, popped, partition, kafka_message(offset: offset, ts: ts) = record) do
      case to_message(state, partition, record) do
        {:ok, message} ->
          pending = %{partition: partition, offset: offset, ts: ts(ts), message: message}
          {:ok, message, %{popped | pending: pending}}

        {:error, %Error{} = error} ->
          drop(state, popped, partition, offset, error)
      end
    end

    defp to_message(state, partition, kafka_message(offset: offset, key: key, value: value, headers: headers)) do
      with {:ok, key} <- key(key) do
        Message.new(state.topic, headers, value(value), key, %Mq.Position{partition: partition, offset: offset})
      end
    end

    defp key(""), do: {:ok, nil}
    defp key(key), do: Mq.Key.new(key)

    defp value(""), do: nil
    defp value(value), do: value

    defp ts(ts) when is_integer(ts), do: ts
    defp ts(_undefined), do: nil

    # Отказ повторился бы на каждом чтении: смещение записи фиксируется, и чтение идёт дальше.
    # Не записалось — запись остаётся в голове буфера, отказ уходит вызывающему.
    defp drop(state, popped, partition, offset, error) do
      case commit_offset(popped, partition, offset) do
        {:ok, popped} ->
          Logger.error(
            "kafka reader: запись пропущена, её не принимает Mq.Message: topic=#{state.topic_name} " <>
              "partition=#{partition} offset=#{offset} ошибка=#{Error.format_chain(error)}"
          )

          :telemetry.execute(Telemetry.event([:mq, :kafka, :decode_drop]), %{count: 1}, %{topic: state.topic_name})
          take(popped)

        {:error, %Error{} = commit_error, %__MODULE__{lease: nil} = lost} ->
          {:error, commit_error, lost}

        {:error, %Error{} = commit_error, _popped} ->
          {:error, commit_error, state}
      end
    end

    defp commit_offset(state, partition, offset) do
      case store_commit(state, partition, offset + 1) do
        :ok ->
          _ = brod_call(fn -> :brod.consume_ack(state.client, state.topic_name, partition, offset) end)
          {:ok, state}

        {:error, %Error{code: :kafka_lease_lost} = error} ->
          Logger.warning(
            "kafka reader: commit отклонён, аренда потеряна: topic=#{state.topic_name} " <>
              "subscriber=#{state.subscriber} partition=#{partition} offset=#{offset}"
          )

          {:error, error, lose_lease(state)}

        {:error, %Error{} = error} ->
          {:error, error, state}
      end
    end

    defp store_commit(state, partition, next_offset) do
      Store.commit(state.repo, state.subscriber, state.topic_name, state.lease, partition, next_offset)
    rescue
      exception -> {:error, commit_failed(Exception.message(exception))}
    catch
      :exit, reason -> {:error, commit_failed(reason)}
    end

    defp commit_failed(detail) do
      Error.app(code: :commit_failed, ns: :mq, message: "Не удалось сохранить смещение Kafka", detail: detail)
    end

    # Непойманное исключение или exit клиента `:brod` (клиент не запущен, консьюмер умер между
    # поиском и вызовом) уронил бы читатель: такой сбой — повод для переподписки, а не рестарта.
    defp brod_call(fun) do
      fun.()
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      :exit, reason -> {:error, reason}
    end
  end
end
