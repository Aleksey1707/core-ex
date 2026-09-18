defmodule Core.Es.KeyReservationRaceTest do
  # Участники гонки коммитят по-настоящему: sandbox-транзакция теста одна на всех и
  # конкурентной записи не даёт. Отсюда `async: false` и очистка таблиц после теста.
  use ExUnit.Case, async: false

  import Core.EsAggregateRepoContract, only: [execute!: 2, open: 1]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.Helper.Transact
  alias Core.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  require Config

  @repo Config.repo!(Account.KeyedRepo)
  @timeout 5_000

  setup do
    on_exit(fn ->
      Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!("TRUNCATE es_events, es_key_reservations, outbox")
      end)
    end)
  end

  test "резерв одного ключа: второй ждёт commit первого — отказ code:, транзакция пригодна" do
    [owner, rival] = [Account.ID.new(), Account.ID.new()]
    first = participant()
    second = participant()

    assert :ok = step(first, fn -> reserve(owner, "Приёмка") end)
    [[backend]] = step(second, fn -> TestRepo.query!("SELECT pg_backend_pid()").rows end)

    send_step(second, fn -> reserve(rival, "Приёмка") end)
    await_lock_wait(backend)
    assert :ok = commit(first)

    assert {:error, %Error{code: :name_taken, detail: %{scope: "fixture.name"}}} = await_step(second)
    assert %Postgrex.Result{num_rows: 1} = step(second, fn -> TestRepo.query!("SELECT 1") end)
    assert :ok = commit(second)
    assert find("Приёмка") == owner
  end

  test "резерв одного ключа: откат первого — второй занимает ключ" do
    [owner, rival] = [Account.ID.new(), Account.ID.new()]
    first = participant()
    second = participant()

    assert :ok = step(first, fn -> reserve(owner, "Приёмка") end)
    [[backend]] = step(second, fn -> TestRepo.query!("SELECT pg_backend_pid()").rows end)

    send_step(second, fn -> reserve(rival, "Приёмка") end)
    await_lock_wait(backend)
    assert {:error, :rollback} = rollback(first)

    assert :ok = await_step(second)
    assert :ok = commit(second)
    assert find("Приёмка") == rival
  end

  test "команды одного потока с разными ключами: вторая — :version_mismatch, а не нарушение уникальности" do
    id = Account.ID.new()
    first = participant()
    second = participant()

    assert :ok = step(first, fn -> append(id, "Приёмка") end)
    [[backend]] = step(second, fn -> TestRepo.query!("SELECT pg_backend_pid()").rows end)

    send_step(second, fn -> append(id, "Отгрузка") end)
    await_lock_wait(backend)
    assert :ok = commit(first)

    assert {:error, %Error{code: :version_mismatch}} = await_step(second)
    assert {:error, :rollback} = rollback(second)
    assert find("Приёмка") == id
    assert find("Отгрузка") == nil
  end

  # Участник держит свою транзакцию вне sandbox и исполняет присланные шаги по одному,
  # пока не получит `:commit` или `:rollback`.
  defp participant do
    test = self()

    Task.async(fn -> Sandbox.unboxed_run(TestRepo, fn -> transact(test) end) end)
  end

  defp transact(test), do: Transact.run(TestRepo, fn -> serve(test) end)

  defp serve(test) do
    receive do
      {:step, fun} ->
        send(test, {:step, self(), fun.()})
        serve(test)

      :commit ->
        :ok

      :rollback ->
        {:error, :rollback}
    end
  end

  defp step(participant, fun) do
    send_step(participant, fun)
    await_step(participant)
  end

  defp send_step(%Task{pid: pid}, fun), do: send(pid, {:step, fun})

  defp await_step(%Task{pid: pid}) do
    assert_receive {:step, ^pid, result}, @timeout
    result
  end

  # Запрос участника дошёл до ожидания блокировки: без этого исход конкурента мог бы его
  # опередить, и тест не отличил бы ожидание на unique от записи после commit.
  defp await_lock_wait(backend) do
    Sandbox.unboxed_run(TestRepo, fn -> poll_lock_wait(backend) end)
  end

  defp poll_lock_wait(backend) do
    sql = "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1"

    case TestRepo.query!(sql, [backend]) do
      %Postgrex.Result{rows: [["Lock"]]} -> :ok
      %Postgrex.Result{} -> poll_lock_wait(backend)
    end
  end

  defp commit(%Task{pid: pid} = participant) do
    send(pid, :commit)
    Task.await(participant, @timeout)
  end

  defp rollback(%Task{pid: pid} = participant) do
    send(pid, :rollback)
    Task.await(participant, @timeout)
  end

  defp reserve(id, name) do
    {events, _state} = execute!(%Account{id: id}, open(name))
    keys = [Account.NameKey.__es_key_reservation__()]

    Es.KeyReservation.append(keys, events, Context.new(), &Account.Errors.domain(Account.KeyedRepo, &1, &2))
  end

  defp append(id, name) do
    {events, _state} = execute!(%Account{id: id}, open(name))
    @repo.append(events, Context.new())
  end

  defp find(name) do
    Sandbox.unboxed_run(TestRepo, fn -> Account.NameKey.find(Account.Name.new!(name), Context.new()) end)
  end
end
