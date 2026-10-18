defmodule Core.Es.Aggregate.Process.ServerTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Es.Aggregate.Process.Server
  alias Core.EsFixture.Account
  alias Core.Version

  describe "stale?/3" do
    test "состояние устарело — возраст от полного чтения больше предела" do
      cases = [
        {1_000, 1_000, 300_000, false},
        {1_000, 300_999, 300_000, false},
        {1_000, 301_000, 300_000, false},
        {1_000, 301_001, 300_000, true},
        {-5_000, 296_001, 300_000, true},
        {1_000, 1_000_000_000, :infinity, false}
      ]

      for {read_at, now, max_age, stale} <- cases do
        assert Server.stale?(read_at, now, max_age) == stale,
               "read_at=#{read_at} now=#{now} max_age=#{inspect(max_age)}"
      end
    end
  end

  describe "stale_in/3" do
    test "остаток до устаревания — мс, после которых stale?/3 станет true; устаревшее — 0" do
      cases = [
        {1_000, 1_000, 300_000, 300_001},
        {1_000, 300_999, 300_000, 2},
        {1_000, 301_000, 300_000, 1},
        {1_000, 301_001, 300_000, 0},
        {-5_000, 400_000, 300_000, 0},
        {1_000, 1_000_000_000, :infinity, :infinity}
      ]

      for {read_at, now, max_age, left} <- cases do
        assert Server.stale_in(read_at, now, max_age) == left,
               "read_at=#{read_at} now=#{now} max_age=#{inspect(max_age)}"
      end
    end
  end

  describe "format_status/1" do
    test "агрегат с ПДн: состояние — тип, aggregate_id и версия; сообщение — модуль команды; reason как есть" do
      server = server(personal: true)
      reason = {:function_clause, []}
      status = %{state: server, message: execute_message(), reason: reason, log: []}

      assert Server.format_status(status) == %{
               state: %{type: "account", aggregate_id: server.aggregate_id, version: Version.new!(1)},
               message: Account.Cmd.Rename,
               reason: reason,
               log: []
             }
    end

    test "агрегат с ПДн без состояния и не команда в сообщении: версия nil, сообщение как есть" do
      server = %{server(personal: true) | state: nil}
      status = Server.format_status(%{state: server, message: :timeout, reason: :normal, log: []})

      assert status.state == %{type: "account", aggregate_id: server.aggregate_id, version: nil}
      assert status.message == :timeout
    end

    test "агрегат без ПДн — статус как есть" do
      status = %{state: server(personal: false), message: execute_message(), reason: :normal, log: []}
      assert Server.format_status(status) == status
    end
  end

  defp server(personal: personal) do
    cfg = %{Account.Process.__es_aggregate_process__() | personal: personal}
    id = Account.ID.new()

    %Server{
      cfg: cfg,
      id: id,
      aggregate_id: Account.ID.value(id),
      idle_timeout: 60_000,
      state_max_age: 300_000,
      state: %Account{id: id, version: Version.new!(1), name: Account.Name.new!("Иван Петров")},
      read_at: 0
    }
  end

  defp execute_message do
    command = %Account.Cmd.Rename{name: Account.Name.new!("Иван Петров"), by: nil, at: nil}
    call = %{id: Account.ID.new(), version: :current, command: command, context: Context.new(), fun: nil}
    {:execute, %{call: call}}
  end
end
