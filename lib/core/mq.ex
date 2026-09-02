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
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 200,
      re: ~r/^[a-zA-Z0-9_-]+$/
  end

  defmodule HeaderKey do
    @moduledoc """
    Ключ заголовка (приводится к lowercase).
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 1,
      max_len: 100,
      re: ~r/^[a-zA-Z0-9._-]+$/,
      mutate: &__MODULE__.downcase/2

    @doc false
    @spec downcase(String.t(), keyword()) :: {:ok, String.t()}

    def downcase(value, _opts) when is_binary(value),
      do: {:ok, String.downcase(value)}
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
    Сообщение MQ.
    """

    @enforce_keys ~w(topic headers body)a
    defstruct @enforce_keys ++ ~w(key)a

    @type headers :: %{String.t() => String.t()}

    @type t :: %__MODULE__{
            topic: Topic.t(),
            headers: headers(),
            body: binary(),
            key: Key.t() | nil
          }

    @doc "Создать сообщение. Ключи заголовков нормализуются в lowercase."
    @spec new(Topic.t(), headers(), binary(), Key.t() | nil) ::
            {:ok, t()} | {:error, Error.t()}

    def new(topic, headers, body, key \\ nil)

    def new(%Topic{} = topic, headers, body, key)
        when is_map(headers) and is_binary(body) and is_opt(key, Key) do
      with {:ok, headers} <- normalize_headers(headers) do
        {:ok,
         %__MODULE__{
           topic: topic,
           headers: headers,
           body: body,
           key: key
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
           Error.domain(__MODULE__,
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
        {k, v}, acc when is_binary(v) ->
          case HeaderKey.new(to_string(k)) do
            {:ok, key} ->
              {:cont, Map.put(acc, HeaderKey.value(key), v)}

            {:error, %Error{} = error} ->
              {:halt, {:error, error}}
          end

        {k, v}, _acc ->
          {:halt,
           {:error,
            Error.domain(__MODULE__,
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
  end
end
