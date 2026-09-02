defmodule Core.Mq.Codec do
  @moduledoc """
  Кодирование `Message` в binary для RabbitMQ Stream (и обратно).
  """

  alias Core.Error
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Option

  require Error

  @doc "Message → JSON binary."
  @spec encode(Message.t()) :: {:ok, binary()} | {:error, Error.t()}

  def encode(%Message{} = message) do
    payload = %{
      "headers" => message.headers,
      "body" => Base.encode64(message.body),
      "key" => Option.map(message.key, &Mq.Key.value/1),
      "topic" => Mq.Topic.value(message.topic)
    }

    case Jason.encode(payload) do
      {:ok, binary} ->
        {:ok, binary}

      {:error, reason} ->
        {:error,
         Error.app(__MODULE__,
           code: :encode_failed,
           ns: :mq,
           message: "Не удалось закодировать MQ message",
           detail: reason
         )}
    end
  end

  @doc "JSON binary → Message."
  @spec decode(binary()) :: {:ok, Message.t()} | {:error, Error.t()}

  def decode(raw) when is_binary(raw) do
    with {:ok, map} <- decode_json(raw),
         {:ok, body} <- decode_body(map["body"]),
         {:ok, topic} <- decode_topic(map["topic"]),
         {:ok, key} <- decode_key(map["key"]),
         {:ok, headers} <- decode_headers(map["headers"]) do
      Message.new(topic, headers, body, key)
    end
  end

  # ---

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, other} ->
        {:error,
         Error.app(__MODULE__,
           code: :invalid_payload,
           ns: :mq,
           message: "Некорректный payload MQ",
           detail: other
         )}

      {:error, reason} ->
        {:error,
         Error.app(__MODULE__,
           code: :invalid_payload,
           ns: :mq,
           message: "Некорректный payload MQ",
           detail: reason
         )}
    end
  end

  defp decode_body(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, body} ->
        {:ok, body}

      :error ->
        {:error,
         Error.app(__MODULE__,
           code: :invalid_body,
           ns: :mq,
           message: "Некорректный body MQ",
           detail: encoded
         )}
    end
  end

  defp decode_body(other) do
    {:error,
     Error.app(__MODULE__,
       code: :invalid_body,
       ns: :mq,
       message: "Некорректный body MQ",
       detail: other
     )}
  end

  defp decode_topic(topic) when is_binary(topic), do: Mq.Topic.new(topic)

  defp decode_topic(other) do
    {:error,
     Error.app(__MODULE__,
       code: :invalid_topic,
       ns: :mq,
       message: "Некорректный topic MQ",
       detail: other
     )}
  end

  defp decode_key(nil), do: {:ok, nil}
  defp decode_key(key) when is_binary(key), do: Mq.Key.new(key)

  defp decode_key(other) do
    {:error,
     Error.app(__MODULE__,
       code: :invalid_key,
       ns: :mq,
       message: "Некорректный key MQ",
       detail: other
     )}
  end

  defp decode_headers(headers) when is_map(headers) do
    if Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, headers}
    else
      {:error,
       Error.app(__MODULE__,
         code: :invalid_headers,
         ns: :mq,
         message: "Некорректные headers MQ",
         detail: headers
       )}
    end
  end

  defp decode_headers(other) do
    {:error,
     Error.app(__MODULE__,
       code: :invalid_headers,
       ns: :mq,
       message: "Некорректные headers MQ",
       detail: other
     )}
  end
end
