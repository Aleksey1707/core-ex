defmodule Core.Web.MetricsPlugTest do
  use ExUnit.Case, async: true

  alias Core.Web

  defmodule Metrics do
    @moduledoc false

    use PromEx, otp_app: :core

    @impl true
    def plugins, do: []
  end

  setup do
    start_supervised!(Metrics)
    :ok
  end

  test "отдаёт метрики на своём пути" do
    conn = Plug.Test.conn(:get, "/metrics") |> call()

    assert conn.status == 200
    assert conn.halted
  end

  test "на чужом пути отвечает 404, а не пропускает conn дальше" do
    conn = Plug.Test.conn(:get, "/другой") |> call()

    assert conn.status == 404
    assert conn.resp_body == "Not Found"
    assert conn.halted
  end

  # ---

  defp call(conn) do
    Web.MetricsPlug.call(conn, Web.MetricsPlug.init(prom_ex_module: Metrics, path: "/metrics"))
  end
end
