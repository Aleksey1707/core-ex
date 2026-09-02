defmodule Core.Mq.Stream.Credentials do
  @moduledoc """
  Параметры подключения к RabbitMQ Stream (пароль скрыт в Inspect).

  Дефолты — стандартные для RabbitMQ Stream protocol, не приложения.
  """

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
  @spec new(keyword()) :: t()

  def new(opts) when is_list(opts) do
    %__MODULE__{
      host: Keyword.get(opts, :host, "localhost"),
      port: Keyword.get(opts, :port, 5552),
      vhost: Keyword.get(opts, :vhost, "/"),
      username: Keyword.get(opts, :username, "guest"),
      password: Keyword.get(opts, :password, "guest")
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

  defimpl Inspect do
    @doc false
    @impl true
    def inspect(%{password: _} = creds, opts) do
      Inspect.Algebra.to_doc(%{creds | password: "***"}, opts)
    end
  end
end
