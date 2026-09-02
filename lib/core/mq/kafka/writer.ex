defmodule Core.Mq.Kafka.Writer do
  @moduledoc """
  `Mq.Writer` для Kafka через klife-клиент.

  Handle writer'а — модуль клиента (`use Klife.Client`) из app-слоя;
  собственного состояния нет.
  Публикация строго по порядку, стоп на первой ошибке.
  """

  @behaviour Core.Mq.Writer

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Telemetry

  require Error

  @doc "Опубликовать сообщение."
  @spec put(module(), Message.t()) :: :ok | {:error, Error.t()}

  @impl true
  def put(client, %Message{} = message) when is_atom(client) do
    case put_many(client, [message]) do
      :ok -> :ok
      {:error, _index, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Опубликовать сообщения по порядку; стоп на первой ошибке."
  @spec put_many(module(), [Message.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}

  @impl true
  def put_many(client, messages) when is_atom(client) and is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
      case put_one(client, message) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, index, error}}
      end
    end)
  end

  # ---

  defp put_one(client, %Message{} = message) do
    topic = Mq.Topic.value(message.topic)
    start = System.monotonic_time()

    case produce(client, to_klife(message)) do
      {:ok, _} ->
        emit_publish(start, :ok, topic)
        :ok

      {:error, %Klife.Record{error_code: code}} ->
        emit_publish(start, :error, topic)
        kafka_error(code)

      {:error, reason} ->
        emit_publish(start, :error, topic)
        kafka_error(reason)
    end
  end

  defp emit_publish(start, result, topic) do
    :telemetry.execute(
      Telemetry.event([:mq, :kafka, :publish]),
      %{duration: System.monotonic_time() - start, count: 1},
      %{result: result, topic: topic}
    )
  end

  defp produce(client, record) do
    case client.produce(record) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, normalize_klife_reason(reason)}
    end
  rescue
    e in RuntimeError -> {:error, normalize_klife_reason(e)}
  end

  defp to_klife(%Message{} = message) do
    %Klife.Record{
      topic: Mq.Topic.value(message.topic),
      key: key(message.key),
      value: message.body,
      headers: Enum.map(message.headers, fn {key, value} -> %{key: key, value: value} end)
    }
  end

  defp key(nil), do: nil
  defp key(%Mq.Key{} = key), do: Mq.Key.value(key)

  defp normalize_klife_reason(:unkown_metadata_for_topic), do: :unknown_metadata_for_topic

  defp normalize_klife_reason({:error, :unkown_metadata_for_topic}),
    do: :unknown_metadata_for_topic

  defp normalize_klife_reason(%RuntimeError{message: message}) do
    if String.contains?(message, "unkown_metadata_for_topic") or
         String.contains?(message, "unknown_metadata_for_topic"),
       do: :unknown_metadata_for_topic,
       else: String.replace(message, "unkown", "unknown")
  end

  defp normalize_klife_reason(reason), do: reason

  defp kafka_error(reason) do
    {:error,
     Error.app(__MODULE__,
       code: :kafka_publish_failed,
       ns: :mq,
       message: "Не удалось опубликовать сообщение в Kafka",
       detail: reason
     )}
  end
end
