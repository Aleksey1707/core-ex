defmodule Core.Web.MetricsPlug do
  @moduledoc """
  Плаг сервера метрик: делегирует в `PromEx.Plug`, а на прочих путях отвечает 404.

  `PromEx.Plug` рассчитан на подключение в pipeline: на чужом пути он просто пропускает
  conn дальше. В standalone-сервере за ним никого нет — без явного ответа адаптер
  (Bandit / Cowboy) падает с `Plug.Conn.NotSentError` и отдаёт 500 вместо 404.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn

  @doc false
  @impl true
  def init(opts) when is_list(opts), do: PromEx.Plug.init(opts)

  @doc false
  @impl true
  def call(%Conn{} = conn, opts) do
    case PromEx.Plug.call(conn, opts) do
      %Conn{halted: true} = conn -> conn
      %Conn{} = conn -> not_found(conn)
    end
  end

  # ---

  defp not_found(%Conn{} = conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
