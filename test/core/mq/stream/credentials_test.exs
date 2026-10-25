defmodule Core.Mq.Stream.CredentialsTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Stream.Credentials

  test "дефолты — стандартные для stream protocol" do
    creds = Credentials.new([])

    assert creds.host == "localhost"
    assert creds.port == 5552
    assert creds.vhost == "/"
    assert creds.username == "guest"
    assert creds.password == "guest"
  end

  test "from_env читает app-env вызывающего" do
    Application.put_env(:core, __MODULE__, host: "broker", port: 5553, username: "app")
    on_exit(fn -> Application.delete_env(:core, __MODULE__) end)

    creds = Credentials.from_env(:core, __MODULE__)

    assert creds.host == "broker"
    assert creds.port == 5553
    assert creds.username == "app"
    assert creds.vhost == "/"
  end

  test "to_connection_opts отдаёт keyword для клиента" do
    opts = Credentials.to_connection_opts(Credentials.new(host: "broker", password: "s3cret"))

    assert Keyword.fetch!(opts, :host) == "broker"
    assert Keyword.fetch!(opts, :password) == "s3cret"
    assert Keyword.keys(opts) == ~w(host port vhost username password)a
  end

  test "inspect не печатает пароль и завершается" do
    creds = Credentials.new(host: "broker", password: "s3cret")

    task = Task.async(fn -> inspect(creds) end)

    assert {:ok, printed} = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
    refute printed =~ "s3cret"
    assert printed =~ "broker"
  end

  test "опечатка в ключе → ArgumentError" do
    assert_raise ArgumentError, ~r/^Core.Mq.Stream.Credentials.new\/1: unknown options \[:hots\]/, fn ->
      Credentials.new(hots: "broker")
    end
  end

  test "отказ по паролю не печатает его значение" do
    error = assert_raise ArgumentError, fn -> Credentials.new(password: ~c"s3cret") end

    assert Exception.message(error) =~ ":password"
    refute Exception.message(error) =~ "s3cret"
  end
end
