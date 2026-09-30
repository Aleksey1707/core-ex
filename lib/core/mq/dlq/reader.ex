defmodule Core.Mq.Dlq.Reader do
  @moduledoc """
  `Mq.ReaderReliable` из таблицы `mq_dlq` (`Core.Mq.Dlq`): отдаёт записи `requeued` одного
  топика одного подписчика по возрастанию `id`.

  Перечитывание — `Core.PubSub.MqSubscriberReliable` с тем же `from_message` / `on_message`, что
  у исходного топика, поверх этого читателя. Сообщение — то, что пришло подписчику из источника:
  топик — `topic:` читателя, ключ, заголовки источника (без `x-dlq-*`), тело и позиция в
  источнике (`Message.position`, `nil` — адаптер её не отдал).

  `get` захватывает старейшую свободную запись на `lease_ttl_ms` (`Core.Mq.Dlq.Store`); в
  работе — одна запись на читатель, и `get` без `commit` отдаёт её же, продлевая захват. Запись,
  захват которой перехватила другая нода, читатель бросает с `warning` и берёт следующую.
  `commit` помечает запись `processed`, не удаляя её; у перехваченной —
  `{:error, %Error{code: :dlq_lease_lost}}`. Две ноды с читателем одного топика читают разные
  записи — порядок между ними не держится, как и порядок относительно исходного топика.
  Штатная остановка отдаёт захват сразу.

  Сбой Postgres — `{:error, %Error{}}` (`:dlq_read_failed`, `:commit_failed`), читатель жив.

  ## Опции

  Обязательные: `repo:` (Ecto-репозиторий с таблицей `Core.Mq.Dlq.Migration`), `topic:`
  (`Mq.Topic` — исходный топик), `subscriber_name:` (`Mq.SubscriberName` — тот же, что у
  `Core.Mq.Dlq.Writer`). Необязательные: `lease_ttl_ms:` (default 60 000), `name:`, `shutdown:`.
  """

  @behaviour Core.Mq.ReaderReliable

  use GenServer

  alias Core.Error
  alias Core.Helper.StartOpts
  alias Core.Mq
  alias Core.Mq.Dlq.Store
  alias Core.Mq.Message

  require Error
  require Logger

  @label "Mq.Dlq.Reader"
  @keys ~w(repo topic subscriber_name lease_ttl_ms name shutdown)a
  @shutdown_ms 15_000
  # `get` и `commit` — запросы в базу: запас на таймаут запроса Ecto.
  @call_timeout 20_000
  @lease_ttl_ms 60_000
  @poll_ms 100

  defstruct [:repo, :topic, :topic_name, :subscriber, :lease, :lease_ttl_ms, pending: nil]

  @type t :: GenServer.server()

  @doc """
  Спецификация ребёнка супервизора.

  `:shutdown` (default #{@shutdown_ms} мс) — запас на `terminate/2`: читатель отдаёт захват
  записи в работе, иначе следующий ждёт истечения `lease_ttl_ms`.
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

  @doc "Прочитать следующую возвращённую запись; `timeout` — сколько ждать её появления."
  @spec get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}

  @impl true
  def get(server, timeout \\ 0)

  def get(server, 0), do: GenServer.call(server, :get, @call_timeout)

  def get(server, timeout) when timeout == :infinity or (is_integer(timeout) and timeout > 0),
    do: poll(server, deadline(timeout))

  @doc "Пометить запись в работе обработанной."
  @spec commit(t()) :: :ok | {:error, Error.t()}

  @impl true
  def commit(server), do: GenServer.call(server, :commit, @call_timeout)

  @doc false
  @impl true
  def init(opts) do
    # Захват записи — внешний ресурс: без trap_exit штатная остановка супервизором не вызывает
    # terminate/2, и следующий читатель ждёт истечения захвата.
    Process.flag(:trap_exit, true)
    StartOpts.keys!(@label, opts, @keys)
    topic = StartOpts.prim!(@label, opts, :topic, Mq.Topic)

    state = %__MODULE__{
      repo: StartOpts.module!(@label, opts, :repo),
      topic: topic,
      topic_name: Mq.Topic.value(topic),
      subscriber: Mq.SubscriberName.value(StartOpts.prim!(@label, opts, :subscriber_name, Mq.SubscriberName)),
      lease: Store.new_lease(),
      lease_ttl_ms: StartOpts.pos_integer!(@label, opts, :lease_ttl_ms, @lease_ttl_ms)
    }

    {:ok, state}
  end

  @doc false
  @impl true
  def handle_call(:get, _from, state) do
    case safe(fn -> take(state) end, &read_failed/1) do
      {:ok, message, state} -> {:reply, {:ok, message}, state}
      {:empty, state} -> {:reply, :empty, state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:commit, _from, %__MODULE__{pending: nil} = state) do
    {:reply, {:error, Error.app(code: :nothing_to_commit, ns: :mq, message: "Нет сообщения для commit")}, state}
  end

  def handle_call(:commit, _from, %__MODULE__{pending: {id, _message}} = state) do
    case safe(fn -> Store.commit(state.repo, id, state.lease) end, &commit_failed/1) do
      :ok ->
        {:reply, :ok, %{state | pending: nil}}

      {:error, %Error{code: :dlq_lease_lost} = error} ->
        log_lost(state, id)
        {:reply, {:error, error}, %{state | pending: nil}}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  @doc false
  @impl true
  def terminate(_reason, %__MODULE__{pending: nil}), do: :ok

  def terminate(_reason, %__MODULE__{pending: {id, _message}} = state) do
    _ = safe(fn -> Store.release(state.repo, id, state.lease) end, & &1)
    :ok
  end

  # ---

  defp take(%__MODULE__{pending: nil} = state) do
    case Store.claim(state.repo, state.subscriber, state.topic_name, state.lease, state.lease_ttl_ms) do
      {:ok, claimed} -> to_pending(state, claimed)
      :none -> {:empty, state}
    end
  end

  defp take(%__MODULE__{pending: {id, message}} = state) do
    case Store.hold(state.repo, id, state.lease, state.lease_ttl_ms) do
      :ok ->
        {:ok, message, state}

      :lost ->
        log_lost(state, id)
        take(%{state | pending: nil})
    end
  end

  defp to_pending(state, claimed) do
    case to_message(state, claimed) do
      {:ok, message} -> {:ok, message, %{state | pending: {claimed.id, message}}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp to_message(state, claimed) do
    with {:ok, key} <- key(claimed.key) do
      headers = Enum.zip(claimed.header_names, claimed.header_values)
      Message.new(state.topic, headers, claimed.body, key, position(claimed))
    end
  end

  defp key(nil), do: {:ok, nil}
  defp key(value), do: Mq.Key.new(value)

  defp position(%{offset: nil}), do: nil
  defp position(%{partition: partition, offset: offset}), do: %Mq.Position{partition: partition, offset: offset}

  defp log_lost(state, id) do
    Logger.warning(
      "dlq reader: захват записи перехвачен, запись брошена: id=#{id} topic=#{state.topic_name} " <>
        "subscriber=#{state.subscriber}"
    )
  end

  defp safe(fun, wrap) do
    fun.()
  rescue
    exception -> {:error, wrap.(Exception.message(exception))}
  catch
    :exit, reason -> {:error, wrap.(reason)}
  end

  defp read_failed(detail) do
    Error.app(code: :dlq_read_failed, ns: :mq, message: "Не удалось прочитать запись DLQ", detail: detail)
  end

  defp commit_failed(detail) do
    Error.app(code: :commit_failed, ns: :mq, message: "Не удалось пометить запись DLQ обработанной", detail: detail)
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
      Process.sleep(@poll_ms)
      poll(server, deadline)
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp timed_out?(:infinity), do: false
  defp timed_out?(deadline), do: System.monotonic_time(:millisecond) >= deadline
end
