defmodule Core.Mq do
  @moduledoc """
  Сообщение и примитивы MQ (stream / in-memory).
  """

  import Core.Helper.String, only: [first_line: 1]
  import Core.Guard, only: [is_opt: 2]

  alias Core.Error

  require Error

  defmodule Topic do
    @moduledoc """
    Имя топика (stream).
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 200,
      re: ~r/^[a-zA-Z0-9._-]+$/
  end

  defmodule Key do
    @moduledoc """
    Ключ сообщения (партиционирование / message_id).

    Непустые байты без верхнего предела и без требования UTF-8: формат ключа чужого топика задаёт
    его владелец, и ключ с Schema Registry — Avro-байты с magic byte (ADR-0032). Значение не
    обязано быть печатаемым: в лог и JSON его выводят с учётом этого.
    """

    use Core.Prim,
      cast: &__MODULE__.cast/1,
      name: first_line(@moduledoc),
      kind: :mq_key,
      value_type: binary()

    @doc false
    @spec cast(term()) :: {:ok, binary()} | {:error, {:invalid_key, String.t()}}

    def cast(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}

    def cast(_value), do: {:error, {:invalid_key, "ожидаются непустые байты"}}
  end

  defmodule HeaderKey do
    @moduledoc """
    Ключ заголовка — любая непустая строка UTF-8, приводится к lowercase.

    Имена заголовков чужого топика задаёт его владелец (ADR-0032): ограничение на алфавит
    отбросило бы его сообщения.
    """

    use Core.Prim,
      cast: &__MODULE__.cast/1,
      name: first_line(@moduledoc),
      kind: :mq_header_key,
      value_type: String.t()

    @doc false
    @spec cast(term()) :: {:ok, String.t()} | {:error, {:invalid_header_key, String.t()}}

    def cast(value) when is_binary(value) and byte_size(value) > 0 do
      if String.valid?(value),
        do: {:ok, String.downcase(value)},
        else: {:error, {:invalid_header_key, "невалидная UTF-8 строка"}}
    end

    def cast(_value), do: {:error, {:invalid_header_key, "ожидается непустая строка"}}
  end

  defmodule Position do
    @moduledoc """
    Позиция прочитанного сообщения в источнике.

    Заполняет читатель: `Mq.Kafka.Reader` — партицию и смещение, `Mq.Stream.Reader` — смещение
    при `partition: nil`. Writer'ы брокеров её не читают (ADR-0032); `Mq.Dlq.Writer` сохраняет
    позицию выброшенного сообщения, и `Mq.Dlq.Reader` отдаёт её при перечитывании.
    """

    @enforce_keys ~w(partition offset)a
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            partition: non_neg_integer() | nil,
            offset: non_neg_integer()
          }
  end

  defmodule SubscriberName do
    @moduledoc """
    Имя подписчика (для независимого offset / cursor).
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 200,
      re: ~r/^[a-zA-Z0-9._-]+$/
  end

  defmodule Message do
    @moduledoc """
    Сообщение MQ — запись топика, которым библиотека может и не владеть (ADR-0032).

    `body: nil` — удаление ключа в компактном топике (tombstone). `position` — место
    прочитанного сообщения в источнике (`Mq.Position`); у публикуемого — `nil`.
    """

    @enforce_keys ~w(topic headers body)a
    defstruct @enforce_keys ++ ~w(key position)a

    @type headers :: %{String.t() => String.t()}

    @typedoc "Заголовки на входе `new`: map или список пар с повторами имён; `nil`-значение — `\"\"`."
    @type headers_in :: %{String.t() => String.t() | nil} | [{String.t(), String.t() | nil}]

    @type t :: %__MODULE__{
            topic: Topic.t(),
            headers: headers(),
            body: binary() | nil,
            key: Key.t() | nil,
            position: Position.t() | nil
          }

    @doc """
    Создать сообщение.

    Имена заголовков нормализуются в lowercase; при повторе имени побеждает последнее значение.
    """
    @spec new(Topic.t(), headers_in(), binary() | nil, Key.t() | nil, Position.t() | nil) ::
            {:ok, t()} | {:error, Error.t()}

    def new(topic, headers, body, key \\ nil, position \\ nil)

    def new(%Topic{} = topic, headers, body, key, position)
        when (is_map(headers) or is_list(headers)) and (is_binary(body) or is_nil(body)) and
               is_opt(key, Key) and is_opt(position, Position) do
      with {:ok, headers} <- normalize_headers(headers) do
        {:ok,
         %__MODULE__{
           topic: topic,
           headers: headers,
           body: body,
           key: key,
           position: position
         }}
      end
    end

    @doc "Найти заголовок или `nil`."
    @spec find_header(t(), HeaderKey.t()) :: String.t() | nil

    def find_header(%__MODULE__{headers: headers}, %HeaderKey{} = key) do
      Map.get(headers, HeaderKey.value(key))
    end

    @doc "Получить заголовок или доменную ошибку."
    @spec get_header(t(), HeaderKey.t()) :: {:ok, String.t()} | {:error, Error.t()}

    def get_header(%__MODULE__{} = message, %HeaderKey{} = key) do
      case find_header(message, key) do
        nil ->
          {:error,
           Error.domain(
             code: :header_not_found,
             ns: :mq,
             message: "Заголовок не найден",
             detail: key
           )}

        value ->
          {:ok, value}
      end
    end

    # ---

    defp normalize_headers(headers) do
      Enum.reduce_while(headers, %{}, fn
        {k, nil}, acc ->
          put_header(acc, k, "")

        {k, v}, acc when is_binary(v) ->
          put_header(acc, k, v)

        {k, v}, _acc ->
          {:halt,
           {:error,
            Error.domain(
              code: :invalid_header_value,
              ns: :mq,
              message: "Значение заголовка должно быть строкой",
              detail: {k, v}
            )}}
      end)
      |> case do
        {:error, _} = err -> err
        acc -> {:ok, acc}
      end
    end

    defp put_header(acc, k, v) do
      case HeaderKey.new(to_string(k)) do
        {:ok, key} -> {:cont, Map.put(acc, HeaderKey.value(key), v)}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end
  end
end
