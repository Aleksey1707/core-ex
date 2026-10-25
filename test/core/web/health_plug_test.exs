defmodule Core.Web.HealthPlugTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureLog

  alias Core.Web

  defmodule DownRepo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :core,
      adapter: Ecto.Adapters.Postgres
  end

  test "/health отвечает 200 ok без проверок репозиториев" do
    conn = Plug.Test.conn(:get, "/health") |> call(repos: [DownRepo])

    assert {conn.status, conn.resp_body} == {200, "ok"}
    assert conn.halted
  end

  test "/ready при живом репозитории — 200 ok" do
    conn = Plug.Test.conn(:get, "/ready") |> call(repos: [TestRepo])

    assert {conn.status, conn.resp_body} == {200, "ok"}
    assert conn.halted
  end

  test "/ready без repos: — репозитории из :ecto_repos приложения" do
    conn = Plug.Test.conn(:get, "/ready") |> call([])

    assert {conn.status, conn.resp_body} == {200, "ok"}
    assert conn.halted
  end

  test "/ready при недоступном репозитории — 503 unavailable и warning в лог" do
    log =
      capture_log([level: :warning], fn ->
        conn = Plug.Test.conn(:get, "/ready") |> call(repos: [TestRepo, DownRepo])

        assert {conn.status, conn.resp_body} == {503, "unavailable"}
        assert conn.halted
      end)

    assert log =~ "repo=#{inspect(DownRepo)}"
  end

  test "свои пути и таймаут из опций" do
    opts = [repos: [TestRepo], health_path: "/live", ready_path: "/status/ready", timeout: 500]

    assert %Plug.Conn{status: 200, halted: true} = Plug.Test.conn(:get, "/live") |> call(opts)
    assert %Plug.Conn{status: 200, halted: true} = Plug.Test.conn(:get, "/status/ready") |> call(opts)
  end

  test "чужой путь проходит дальше без изменений" do
    conn = Plug.Test.conn(:get, "/health/extra")

    assert call(conn, repos: [DownRepo]) == conn
  end

  test "неверные опции — ошибка на init/1" do
    assert_raise ArgumentError, fn -> Web.HealthPlug.init(repos: []) end
    assert_raise ArgumentError, fn -> Web.HealthPlug.init(repos: [Core.Web.HealthPlugTest.NoRepo]) end
    assert_raise ArgumentError, fn -> Web.HealthPlug.init(repos: [Core.Web]) end

    assert_raise ArgumentError, ~r/отличный от health_path:/, fn ->
      Web.HealthPlug.init(repos: [TestRepo], ready_path: "/health/")
    end

    assert_raise ArgumentError, fn -> Web.HealthPlug.init(repos: [TestRepo], timeout: 0) end
    assert_raise ArgumentError, fn -> Web.HealthPlug.init(repos: [TestRepo], ready_path: "ready") end

    assert_raise ArgumentError, ~r/init\/1: unknown options \[:unknown\]/, fn ->
      Web.HealthPlug.init(repos: [TestRepo], unknown: 1)
    end
  end

  # ---

  defp call(conn, opts), do: Web.HealthPlug.call(conn, Web.HealthPlug.init(opts))
end
