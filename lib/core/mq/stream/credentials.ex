defmodule Core.Mq.Stream.Credentials do
  @moduledoc """
  Параметры подключения к RabbitMQ Stream (пароль скрыт в Inspect).

  Дефолты — стандартные для RabbitMQ Stream protocol, не приложения.
  """

  use Core.Options

  defmodule Password do
    @moduledoc false

    @doc false
    @spec validate(term()) :: Core.Result.t(String.t(), String.t())

    def validate(password) when is_binary(password), do: {:ok, password}
    def validate(_password), do: {:error, "ожидается строка (значение скрыто)"}
  end

  @derive {Inspect, except: [:password]}
  @enforce_keys ~w(host port vhost username password)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          host: String.t(),
          port: pos_integer(),
          vhost: String.t(),
          username: String.t(),
          password: String.t()
        }

  @doc "Собрать credentials из keyword."
  @opts_schema [
    host: [type: :string, default: "localhost", doc: "Хост брокера."],
    port: [type: :pos_integer, default: 5552, doc: "Порт RabbitMQ Stream protocol."],
    vhost: [type: :string, default: "/", doc: "Virtual host."],
    username: [type: :string, default: "guest", doc: "Пользователь."],
    password: [
      type: {:custom, Password, :validate, []},
      default: "guest",
      doc: "Пароль: строка; в тексте отказа значение не печатается."
    ]
  ]
  @spec new(keyword()) :: t()

  def new(opts) when is_list(opts) do
    %__MODULE__{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      vhost: Keyword.fetch!(opts, :vhost),
      username: Keyword.fetch!(opts, :username),
      password: Keyword.fetch!(opts, :password)
    }
  end

  @doc "Credentials из `Application.get_env(otp_app, key)`."
  @spec from_env(atom(), module() | atom()) :: t()

  def from_env(otp_app, key) when is_atom(otp_app) and is_atom(key) do
    otp_app
    |> Application.get_env(key, [])
    |> new()
  end

  @doc "Keyword для `RabbitMQStream.Connection`."
  @spec to_connection_opts(t()) :: keyword()

  def to_connection_opts(%__MODULE__{} = creds) do
    [
      host: creds.host,
      port: creds.port,
      vhost: creds.vhost,
      username: creds.username,
      password: creds.password
    ]
  end
end
