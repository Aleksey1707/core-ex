defmodule Core.KafkaFake do
  @moduledoc """
  Поддельный клиент `:brod` без брокера: handle `Mq.Kafka.Writer` — его id, как у настоящего.

  Writer зовёт публичный `:brod.produce_sync/5`, и под подделкой проходит настоящий путь
  клиента: партиционер получает число партиций, пачка собирается из ключа, значения и
  заголовков. Подделка стоит там, где `:brod` уходит к процессам клиента, и держится на его
  раскладке 4.x — ETS-таблица под id клиента с ключами `{:topics, topic}` и
  `{:producer, topic, partition}`, протокол `brod_producer` (`#brod_produce_reply{}`).
  Разойдётся с новой версией `:brod` — поймают тесты `:kafka` на живом брокере.

  Опции `start_link/1`: `client:` — id клиента, `topics:` — `%{topic => число партиций}`
  (топик вне карты — неизвестный), `fail_at:` — индекс запроса, с которого брокер отвечает
  `:message_too_large`: продюсер партиции падает, как `brod_producer`, с причиной `exit:` —
  `:not_retriable` (по умолчанию) или `:reached_max_retries`.

  Метаданные неизвестного топика отдаются только на запрос без автосоздания
  (`{:all, topics}` — `:brod.get_partitions_count_safe/2`): запрос с автосозданием роняет
  подделку, и тест видит `:client_down`.

  Чтение: у каждой партиции — поддельный `brod_consumer` под ключом `{:consumer, topic,
  partition}` с его протоколом (`subscribe` / `unsubscribe` — call, `ack` — cast, пачки —
  `{consumer_pid, #kafka_message_set{}}` в почтовый ящик подписчика). Тест подаёт пачку
  `deliver/5`, ошибку чтения — `fetch_error/4`, перезапуск консьюмера — `restart_consumer/3`;
  подписку и подтверждения видно в `subscription/3`. Новые партиции (`set_partitions/3`)
  получают консьюмеров только после `:brod_client.stop_consumer/2`, как у настоящего клиента.
  """

  use GenServer

  require Record

  Record.defrecordp(:kafka_message, Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl"))

  defmodule Consumer do
    @moduledoc false

    use GenServer

    require Record

    Record.defrecordp(:kafka_message_set, Record.extract(:kafka_message_set, from_lib: "brod/include/brod.hrl"))
    Record.defrecordp(:kafka_fetch_error, Record.extract(:kafka_fetch_error, from_lib: "brod/include/brod.hrl"))

    @spec start_link(String.t(), non_neg_integer()) :: GenServer.on_start()

    def start_link(topic, partition), do: GenServer.start_link(__MODULE__, {topic, partition})

    @impl true
    def init({topic, partition}),
      do: {:ok, %{topic: topic, partition: partition, subscriber: nil, begin_offset: nil, subscribes: 0, acks: []}}

    @impl true
    def handle_call({:subscribe, pid, opts}, _from, state) do
      if is_pid(state.subscriber) and state.subscriber != pid and Process.alive?(state.subscriber) do
        {:reply, {:error, {:already_subscribed_by, state.subscriber}}, state}
      else
        state = %{state | subscriber: pid, begin_offset: opts[:begin_offset], subscribes: state.subscribes + 1}
        {:reply, :ok, state}
      end
    end

    def handle_call({:unsubscribe, pid}, _from, %{subscriber: pid} = state),
      do: {:reply, :ok, %{state | subscriber: nil}}

    def handle_call({:unsubscribe, _pid}, _from, state), do: {:reply, {:error, :ignored}, state}

    def handle_call(:state, _from, state),
      do: {:reply, Map.take(state, ~w(subscriber begin_offset subscribes acks)a), state}

    def handle_call({:deliver, messages, high_wm}, _from, state) do
      set =
        kafka_message_set(topic: state.topic, partition: state.partition, high_wm_offset: high_wm, messages: messages)

      send(state.subscriber, {self(), set})
      {:reply, :ok, state}
    end

    def handle_call({:fetch_error, code}, _from, state) do
      send(
        state.subscriber,
        {self(), kafka_fetch_error(topic: state.topic, partition: state.partition, error_code: code)}
      )

      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:ack, offset}, state), do: {:noreply, %{state | acks: state.acks ++ [offset]}}
  end

  @error_code :message_too_large

  @type produced :: %{
          topic: String.t(),
          partition: non_neg_integer(),
          key: binary(),
          value: binary(),
          headers: [{binary(), binary()}]
        }

  @doc "Спецификация ребёнка: клиент под id `client:`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts),
    do: %{id: Keyword.fetch!(opts, :client), start: {__MODULE__, :start_link, [opts]}}

  @doc "Запустить клиент под id `client:`."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :client))

  @doc "Принятые брокером записи в порядке публикации."
  @spec published(atom()) :: [produced()]

  def published(client) when is_atom(client), do: GenServer.call(client, :published)

  @doc "Подписка поддельного консьюмера партиции: подписчик, `begin_offset`, число подписок и подтверждения."
  @spec subscription(atom(), String.t(), non_neg_integer()) :: map()

  def subscription(client, topic, partition), do: GenServer.call(consumer!(client, topic, partition), :state)

  @doc "Подать подписчику партиции пачку записей `{offset, key, value, headers}`."
  @spec deliver(atom(), String.t(), non_neg_integer(), [tuple()], non_neg_integer()) :: :ok

  def deliver(client, topic, partition, records, high_wm) do
    messages =
      for {offset, key, value, headers} <- records,
          do: kafka_message(offset: offset, key: key, value: value, headers: headers, ts_type: :create, ts: offset)

    GenServer.call(consumer!(client, topic, partition), {:deliver, messages, high_wm})
  end

  @doc "Отправить подписчику партиции ошибку чтения с кодом брокера."
  @spec fetch_error(atom(), String.t(), non_neg_integer(), atom()) :: :ok

  def fetch_error(client, topic, partition, code),
    do: GenServer.call(consumer!(client, topic, partition), {:fetch_error, code})

  @doc "Перезапустить консьюмер партиции, как супервизор `:brod` после сбоя: новый pid без подписчика."
  @spec restart_consumer(atom(), String.t(), non_neg_integer()) :: :ok

  def restart_consumer(client, topic, partition), do: GenServer.call(client, {:restart_consumer, topic, partition})

  @doc "Сменить число партиций топика в метаданных клиента."
  @spec set_partitions(atom(), String.t(), pos_integer()) :: :ok

  def set_partitions(client, topic, count), do: GenServer.call(client, {:set_partitions, topic, count})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    client = Keyword.fetch!(opts, :client)
    table = :ets.new(client, [:named_table, :public, read_concurrency: true])

    for {topic, count} <- Keyword.fetch!(opts, :topics) do
      :ets.insert(table, {{:topics, topic}, count, System.monotonic_time()})

      for partition <- 0..(count - 1) do
        :ets.insert(table, {{:producer, topic, partition}, spawn_producer(topic, partition)})
      end

      start_consumers(table, topic, count)
    end

    {:ok,
     %{
       table: table,
       fail_at: Keyword.get(opts, :fail_at),
       exit: Keyword.get(opts, :exit, :not_retriable),
       requests: 0,
       published: []
     }}
  end

  @impl true
  def handle_call({:get_metadata, {:all, _topics}}, _from, state), do: {:reply, {:ok, %{topics: []}}, state}

  def handle_call(:get_workers_table, _from, state), do: {:reply, {:ok, state.table}, state}

  def handle_call(:get_consumers_sup_pid, _from, state), do: {:reply, {:error, :unknown_topic_or_partition}, state}

  # Остановка и новый старт консьюмеров топика одним шагом: `:brod.start_consumer/3` следом
  # видит консьюмера партиции 0 и отвечает `ok`, как у настоящего клиента после старта.
  def handle_call({:stop_consumer, topic}, _from, state) do
    [{_, count, _}] = :ets.lookup(state.table, {:topics, topic})

    for [partition, pid] <- :ets.match(state.table, {{:consumer, topic, :"$1"}, :"$2"}) do
      Process.exit(pid, :kill)
      :ets.delete(state.table, {:consumer, topic, partition})
    end

    start_consumers(state.table, topic, count)
    {:reply, :ok, state}
  end

  def handle_call({:restart_consumer, topic, partition}, _from, state) do
    [{_, pid}] = :ets.lookup(state.table, {:consumer, topic, partition})
    Process.exit(pid, :kill)
    {:ok, new} = Consumer.start_link(topic, partition)
    :ets.insert(state.table, {{:consumer, topic, partition}, new})
    {:reply, :ok, state}
  end

  def handle_call({:set_partitions, topic, count}, _from, state) do
    :ets.insert(state.table, {{:topics, topic}, count, System.monotonic_time()})
    {:reply, :ok, state}
  end

  def handle_call(:published, _from, state), do: {:reply, Enum.reverse(state.published), state}

  def handle_call({:produce, topic, partition, batch}, _from, state) do
    state = %{state | requests: state.requests + 1}

    if is_integer(state.fail_at) and state.requests > state.fail_at do
      {:reply, {:error, state.exit, @error_code}, state}
    else
      records = Enum.map(batch, &record(topic, partition, &1))
      {:reply, {:ok, length(state.published)}, %{state | published: Enum.reverse(records, state.published)}}
    end
  end

  @impl true
  def handle_info({:EXIT, _producer, _reason}, state), do: {:noreply, state}

  # ---

  defp consumer!(client, topic, partition) do
    [{_, pid}] = :ets.lookup(client, {:consumer, topic, partition})
    pid
  end

  defp start_consumers(table, topic, count) do
    for partition <- 0..(count - 1) do
      {:ok, pid} = Consumer.start_link(topic, partition)
      :ets.insert(table, {{:consumer, topic, partition}, pid})
    end
  end

  defp spawn_producer(topic, partition) do
    owner = self()
    spawn_link(fn -> produce_loop(owner, topic, partition) end)
  end

  # Отказ — выход продюсера до ответа `buffered`: вызывающий уже держит monitor и получает
  # `{:producer_down, reason}` той же формы, что и при отказе брокера у настоящего клиента.
  defp produce_loop(owner, topic, partition) do
    receive do
      {:produce, {:brod_call_ref, caller, _callee, _ref} = call_ref, batch, :undefined} ->
        case GenServer.call(owner, {:produce, topic, partition, batch}) do
          {:ok, offset} ->
            send(caller, {:brod_produce_reply, call_ref, :undefined, :brod_produce_req_buffered})
            send(caller, {:brod_produce_reply, call_ref, offset, :brod_produce_req_acked})
            produce_loop(owner, topic, partition)

          {:error, exit, code} ->
            exit({exit, {:produce_response_error, topic, partition, -1, code}})
        end
    end
  end

  defp record(topic, partition, message) do
    %{
      topic: topic,
      partition: partition,
      key: message.key,
      value: message.value,
      headers: message.headers
    }
  end
end
