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
  """

  @behaviour Core.Outbox.Delivery

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
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
      {:ok, messages} ->
        delivery.writer_module.put_many(delivery.writer, messages)

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

  defp encode_messages([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp encode_messages([record | rest], index, acc) do
    case to_message(record) do
      {:ok, message} -> encode_messages(rest, index + 1, [message | acc])
      {:error, %Error{} = error} -> {:error, index, error, Enum.reverse(acc)}
    end
  end

  # Вызывающий (`Outbox.Poller`) считает всё до индекса опубликованным. Если вернуть
  # индекс ошибки encode, не опубликовав закодированный префикс, эти записи будут
  # помечены `published`, хотя writer не вызывался вовсе.
  defp publish_prefix(_delivery, [], index, %Error{} = error), do: {:error, index, error}

  defp publish_prefix(delivery, encoded, index, %Error{} = error) do
    case delivery.writer_module.put_many(delivery.writer, encoded) do
      :ok -> {:error, index, error}
      {:error, failed, %Error{} = publish_error} -> {:error, failed, publish_error}
    end
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
