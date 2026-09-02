defmodule Core.Security.Secret do
  @moduledoc """
  Зашифрованное секретное значение (Fernet at-rest).

  В struct хранится только шифротекст; plaintext появляется лишь на границе
  `new/1` (вход) и `reveal/1` (выход для внешнего вызова).
  """

  alias Core.Error
  alias Core.Result

  require Error

  @key_bytes 32

  @enforce_keys ~w(cipher)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{cipher: String.t()}

  @doc "Зашифровать plaintext → `%Secret{}`."
  @spec new(String.t()) :: {:ok, t()} | {:error, Error.t()}

  def new(plaintext) when is_binary(plaintext) and plaintext != "" do
    case Fernet.generate(plaintext, key: secret_key()) do
      {:ok, _iv, ciphertext} ->
        {:ok, %__MODULE__{cipher: ciphertext}}

      {:error, reason} ->
        {:error,
         Error.app(__MODULE__,
           code: :encrypt_failed,
           ns: :secret,
           message: "Не удалось зашифровать секрет",
           detail: reason
         )}
    end
  end

  @doc "Собрать `%Secret{}` из уже зашифрованного значения."
  @spec from_cipher(String.t()) :: {:ok, t()} | {:error, Error.t()}

  def from_cipher(cipher) when is_binary(cipher) and cipher != "" do
    {:ok, %__MODULE__{cipher: cipher}}
  end

  @doc "Шифротекст для persist."
  @spec cipher(t()) :: String.t()

  def cipher(%__MODULE__{cipher: cipher}), do: cipher

  @doc "Расшифровать секрет → plaintext."
  @spec reveal(t()) :: {:ok, String.t()} | {:error, Error.t()}

  def reveal(%__MODULE__{cipher: cipher}) do
    case Fernet.verify(cipher, key: secret_key(), enforce_ttl: false) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, reason} ->
        {:error,
         Error.app(__MODULE__,
           code: :decrypt_failed,
           ns: :secret,
           message: "Не удалось расшифровать секрет",
           detail: reason
         )}
    end
  end

  @doc "Как `new/1`, при ошибке — `raise Exc`."
  @spec new!(String.t()) :: t()

  def new!(plaintext), do: Result.unwrap!(new(plaintext))

  @doc "Как `reveal/1`, при ошибке — `raise Exc`."
  @spec reveal!(t()) :: String.t()

  def reveal!(%__MODULE__{} = secret), do: Result.unwrap!(reveal(secret))

  @doc """
  Сравнить секрет с plaintext за постоянное время.

  Обычное `==` над `reveal/1` утекает длину совпавшего префикса по таймингу.
  """
  @spec equal?(t(), String.t()) :: boolean()

  def equal?(%__MODULE__{} = secret, plaintext) when is_binary(plaintext) do
    case reveal(secret) do
      {:ok, revealed} -> Plug.Crypto.secure_compare(revealed, plaintext)
      {:error, _} -> false
    end
  end

  @doc """
  Проверить ключ шифрования (вызывать при старте приложения).

  Проверяется не только наличие, но и формат: Fernet требует 32 байта в base64
  (стандартный или URL-safe алфавит). Иначе неверный ключ всплывал бы не на старте,
  а на первом `new/1` — то есть уже под трафиком.
  """
  @spec ensure_configured!() :: :ok

  def ensure_configured! do
    case Application.get_env(:core, __MODULE__, [])[:secret_key] do
      key when is_binary(key) and key != "" ->
        validate_key!(key)

      _ ->
        raise ArgumentError,
              "не задан `config :core, Core.Security.Secret, secret_key: ...`"
    end
  end

  # ---

  defp validate_key!(key) do
    case decode_key(key) do
      {:ok, decoded} when byte_size(decoded) == @key_bytes ->
        :ok

      {:ok, decoded} ->
        raise ArgumentError,
              "ключ шифрования секретов должен быть #{@key_bytes} байта в base64, " <>
                "получено #{byte_size(decoded)}"

      :error ->
        raise ArgumentError, "ключ шифрования секретов не является корректным base64"
    end
  end

  defp decode_key(key) do
    with :error <- Base.decode64(key), do: Base.url_decode64(key)
  end

  defp secret_key, do: Application.fetch_env!(:core, __MODULE__)[:secret_key]
end

defimpl Inspect, for: Core.Security.Secret do
  @doc false
  @impl true
  def inspect(%Core.Security.Secret{}, _opts), do: "#Secret<...>"
end

# Явный отказ вместо молчаливой утечки шифротекста: без этой реализации достаточно
# одного `@derive Jason.Encoder` выше по стеку, чтобы секрет уехал в JSON.
defimpl Jason.Encoder, for: Core.Security.Secret do
  @doc false
  @impl true
  def encode(%Core.Security.Secret{}, _opts) do
    raise Protocol.UndefinedError,
      protocol: Jason.Encoder,
      value: "#Secret<...>",
      description: "секрет не сериализуется в JSON: отдавайте Secret.reveal/1 осознанно"
  end
end
