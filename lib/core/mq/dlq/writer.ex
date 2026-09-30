defmodule Core.Mq.Dlq.Writer do
  @moduledoc """
  `Mq.Writer` в таблицу `mq_dlq` (`Core.Mq.Dlq`): подключается `dlq_writer:` подписчика
  `Core.PubSub.MqSubscriberReliable`.

  Сообщение становится строкой `dead`. Заголовки DLQ, которые ставит подписчик, ложатся в
  колонки: `x-dlq-source-topic` — `topic` (без него — топик сообщения), `x-dlq-reason`,
  `x-dlq-error`, `x-dlq-attempts`; в `header_names` / `header_values` остаются заголовки
  источника. Ключ, тело и позиция (`Message.position`) пишутся как есть, `nil` — `NULL`.

  Handle — процесс writer'а (`name:`), как у `Mq.Stream.Writer`: он держит репозиторий и
  `subscriber_name`. Сбой Postgres — `{:error, %Error{code: :dlq_write_failed}}`.

  ## Опции

  Обязательные: `repo:` (Ecto-репозиторий с таблицей `Core.Mq.Dlq.Migration`),
  `subscriber_name:` (`Mq.SubscriberName` — чей это DLQ: читатель перечитывания берёт записи
  по нему). Необязательные: `name:`.
  """

  @behaviour Core.Mq.Writer

  use GenServer

  alias Core.Error
  alias Core.Helper.StartOpts
  alias Core.Mq
  alias Core.Mq.Dlq.Store
  alias Core.Mq.Message

  require Error

  @label "Mq.Dlq.Writer"
  @keys ~w(repo subscriber_name name)a
  # Запись — запрос в базу: запас на таймаут запроса Ecto.
  @call_timeout 20_000

  @source_topic "x-dlq-source-topic"
  @reason "x-dlq-reason"
  @error "x-dlq-error"
  @attempts "x-dlq-attempts"
  @dlq_headers [@source_topic, @reason, @error, @attempts]

  defstruct [:repo, :subscriber]

  @type t :: GenServer.server()

  @doc "Запустить writer."
  @spec start_link(keyword()) :: GenServer.on_start()

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Записать сообщение строкой DLQ."
  @spec put(t(), Message.t()) :: :ok | {:error, Error.t()}

  @impl true
  def put(server, %Message{} = message) do
    case put_many(server, [message]) do
      :ok -> :ok
      {:error, 0, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Записать сообщения строками DLQ по порядку; первая ошибка останавливает запись."
  @spec put_many(t(), [Message.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}

  @impl true
  def put_many(server, messages) when is_list(messages) do
    GenServer.call(server, {:put_many, messages}, @call_timeout)
  end

  @doc false
  @impl true
  def init(opts) do
    StartOpts.keys!(@label, opts, @keys)

    state = %__MODULE__{
      repo: StartOpts.module!(@label, opts, :repo),
      subscriber: Mq.SubscriberName.value(StartOpts.prim!(@label, opts, :subscriber_name, Mq.SubscriberName))
    }

    {:ok, state}
  end

  @doc false
  @impl true
  def handle_call({:put_many, messages}, _from, state) do
    result =
      messages
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {message, index}, :ok -> insert(state, message, index) end)

    {:reply, result, state}
  end

  # ---

  defp insert(%__MODULE__{} = state, %Message{} = message, index) do
    case safe_insert(state, message) do
      :ok -> {:cont, :ok}
      {:error, %Error{} = error} -> {:halt, {:error, index, error}}
    end
  end

  defp safe_insert(state, message) do
    Store.insert(state.repo, row(state, message))
  rescue
    exception -> {:error, write_failed(Exception.message(exception))}
  end

  defp row(%__MODULE__{subscriber: subscriber}, %Message{headers: headers} = message) do
    {dlq, source} = Map.split(headers, @dlq_headers)
    {names, values} = Enum.unzip(Enum.sort(source))
    {partition, offset} = position(message.position)

    %{
      subscriber: subscriber,
      topic: Map.get_lazy(dlq, @source_topic, fn -> Mq.Topic.value(message.topic) end),
      key: key(message.key),
      header_names: names,
      header_values: values,
      body: message.body,
      partition: partition,
      offset: offset,
      reason: Map.get(dlq, @reason),
      error: Map.get(dlq, @error),
      attempts: attempts(Map.get(dlq, @attempts))
    }
  end

  defp key(nil), do: nil
  defp key(%Mq.Key{} = key), do: Mq.Key.value(key)

  defp position(nil), do: {nil, nil}
  defp position(%Mq.Position{partition: partition, offset: offset}), do: {partition, offset}

  defp attempts(nil), do: nil

  defp attempts(value) do
    case Integer.parse(value) do
      {attempts, ""} when attempts >= 0 -> attempts
      _other -> nil
    end
  end

  defp write_failed(detail) do
    Error.app(code: :dlq_write_failed, ns: :mq, message: "Не удалось записать сообщение в DLQ", detail: detail)
  end
end
