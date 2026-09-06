defmodule Core.Outbox.Delivery.Mq do
  @moduledoc """
  Доставка outbox-записи через `Mq.Writer` (RabbitMQ Stream или Kafka).

  Headers: `record.headers` как есть; `nil` — сообщение без заголовков.
  Delivery ничего не добавляет от себя — заголовки задаёт продюсер записи.
  Body: JSON через `Jason.encode` (`Record.payload` — всегда JSON-объект).

  `publish_many/2` кодирует записи по порядку и вызывает `Writer.put_many/2`
  (один round-trip); стоп на первой ошибке encode/publish. Возвращаемый индекс —
  всегда первая **неопубликованная** запись: при ошибке encode в середине пачки
  успешно закодированный префикс сначала публикуется, и лишь потом отдаётся ошибка.

  ## Трассировка

  По semantic conventions (`Core.Otel.Messaging`): на каждое сообщение —
  `"create <topic>"` с родителем из `record.headers`, то есть из контекста команды,
  записавшей строку; на отправку пачки — `"send …"` со **ссылками** на контексты
  создания. Контекст create-span'а уходит в заголовки сообщения, поэтому обработчик
  становится потомком создания своего сообщения, а не всего батча.

  Транспортный `traceparent` — единственное, что доставка добавляет к заголовкам
  **сообщения**; `to_message/1` при этом остаётся чистым преобразованием записи
  и заголовков не трогает.
  """

  @behaviour Core.Outbox.Delivery

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Otel
  alias Core.Outbox
  alias Core.Outbox.Record

  require Error

  defstruct [:writer_module, :writer]

  @type t :: %__MODULE__{
          writer_module: module(),
          writer: term()
        }

  @doc "Создать delivery. `writer_module` реализует `Mq.Writer`."
  @spec new(module(), term()) :: t()

  def new(writer_module, writer) when is_atom(writer_module) do
    %__MODULE__{writer_module: writer_module, writer: writer}
  end

  @doc "Опубликовать запись outbox через MQ writer."
  @spec publish(t(), Record.t()) :: :ok | {:error, Error.t()}

  @impl true
  def publish(%__MODULE__{} = delivery, %Record{} = record) do
    case publish_many(delivery, [record]) do
      :ok -> :ok
      {:error, _index, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Опубликовать записи по порядку; стоп на первой ошибке."
  @spec publish_many(t(), [Record.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}

  @impl true
  def publish_many(%__MODULE__{} = delivery, records) when is_list(records) do
    case encode_messages(records, 0, []) do
      {:ok, encoded} ->
        send_batch(delivery, encoded, &publish_result/1)

      {:error, index, %Error{} = error, encoded} ->
        publish_prefix(delivery, encoded, index, error)
    end
  end

  @doc "Record → MQ Message."
  @spec to_message(Record.t()) :: {:ok, Message.t()} | {:error, Error.t()}

  def to_message(%Record{} = record) do
    with {:ok, topic} <- Mq.Topic.new(Outbox.Topic.value(record.topic)),
         {:ok, key} <- Mq.Key.new(Outbox.Key.value(record.key)),
         {:ok, body} <- encode_body(record.payload) do
      Message.new(topic, headers(record), body, key)
    end
  end

  # ---

  # Каждое сообщение получает create-span: его контекст уходит в заголовки, а сам
  # контекст возвращается наверх — send-span обязан на него сослаться.
  defp encode_messages([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp encode_messages([record | rest], index, acc) do
    case to_message(record) do
      {:ok, message} ->
        encode_messages(rest, index + 1, [create_span(record, message) | acc])

      {:error, %Error{} = error} ->
        {:error, index, error, Enum.reverse(acc)}
    end
  end

  defp create_span(%Record{} = record, %Message{} = message) do
    destination = Outbox.Topic.value(record.topic)
    message_id = Outbox.Key.value(record.key)

    {headers, span_ctx} = Otel.Messaging.create(message.headers, destination, message_id)

    {%{message | headers: headers}, span_ctx}
  end

  # Пустая пачка — это провал encode на первой же записи: писателя звать нечем
  # и не за чем, span отправки открывать не над чем.
  defp send_batch(_delivery, [], on_result), do: on_result.(:ok)

  defp send_batch(delivery, encoded, on_result) do
    {messages, links} = Enum.unzip(encoded)
    put_many = fn -> delivery.writer_module.put_many(delivery.writer, messages) end

    Otel.Messaging.send(
      destination(messages),
      length(messages),
      links,
      [operation_name: "publish"],
      fn -> on_result.(put_many.()) end
    )
  end

  # Пачка поллера собирается по нескольким топикам: имя span'а квалифицируется
  # назначением, только когда оно у всей пачки одно (`{operation} {destination}`).
  defp destination(messages) do
    case Enum.uniq(Enum.map(messages, &Mq.Topic.value(&1.topic))) do
      [destination] -> destination
      _many -> nil
    end
  end

  defp publish_result(:ok), do: :ok

  defp publish_result({:error, index, %Error{} = error}) do
    Otel.record_error(error)
    {:error, index, error}
  end

  # Вызывающий (`Outbox.Poller`) считает всё до индекса опубликованным. Если вернуть
  # индекс ошибки encode, не опубликовав закодированный префикс, эти записи будут
  # помечены `published`, хотя writer не вызывался вовсе.
  defp publish_prefix(delivery, encoded, index, %Error{} = error) do
    send_batch(delivery, encoded, fn
      :ok ->
        publish_result({:error, index, error})

      {:error, failed, %Error{} = publish_error} ->
        publish_result({:error, failed, publish_error})
    end)
  end

  defp headers(%Record{headers: headers}) when is_map(headers), do: headers

  defp headers(%Record{headers: nil}), do: %{}

  defp encode_body(payload) do
    case Jason.encode(payload) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         Error.app(__MODULE__,
           code: :encode_payload_failed,
           ns: :outbox,
           message: "Не удалось закодировать payload outbox",
           detail: reason
         )}
    end
  end
end
