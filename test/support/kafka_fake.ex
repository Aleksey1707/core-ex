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
  """

  use GenServer

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
