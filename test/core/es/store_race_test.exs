defmodule Core.Es.StoreRaceTest do
  # Участники гонки коммитят по-настоящему: sandbox-транзакция теста одна на всех и
  # конкурентной записи не даёт. Отсюда `async: false` и очистка таблицы после теста.
  use ExUnit.Case, async: false

  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.Helper.Transact
  alias Core.TestRepo
  alias Core.Version
  alias Ecto.Adapters.SQL.Sandbox

  @codec EventFixture.Event.Codec
  @timeout 5_000

  setup do
    on_exit(fn ->
      Sandbox.unboxed_run(TestRepo, fn -> TestRepo.query!("TRUNCATE es_events") end)
    end)
  end

  test "конкурентная запись одной версии: второй ждёт commit первого на unique — :version_mismatch" do
    id = AggID.new()
    first = participant()
    second = participant()

    assert :ok = step(first, fn -> append([event(id, 1)]) end)
    [[backend]] = step(second, fn -> TestRepo.query!("SELECT pg_backend_pid()").rows end)

    send_step(second, fn -> append([event(id, 1)]) end)
    await_lock_wait(backend)
    assert :ok = commit(first)

    assert {:error, %Error{code: :version_mismatch, detail: %{expected: 1, actual: 1}}} =
             await_step(second)

    assert %Postgrex.Result{num_rows: 1} = step(second, fn -> TestRepo.query!("SELECT 1") end)
    assert :ok = commit(second)
    assert versions(id) == [1]
  end

  test "конкурентная запись одной версии после commit первого — :version_mismatch" do
    id = AggID.new()
    first = participant()
    second = participant()

    assert %Postgrex.Result{} = step(second, fn -> TestRepo.query!("SELECT 1") end)
    assert :ok = step(first, fn -> append([event(id, 1)]) end)
    assert :ok = commit(first)

    assert {:error, %Error{code: :version_mismatch, detail: %{expected: 1, actual: 1}}} =
             step(second, fn -> append([event(id, 1)]) end)

    assert :ok = commit(second)
    assert versions(id) == [1]
  end

  test "страж xid: транзакция получила xid до commit конкурента — :version_mismatch" do
    id = AggID.new()
    older = participant()
    newer = participant()

    assert %Postgrex.Result{} =
             step(older, fn -> TestRepo.query!("SELECT pg_current_xact_id()") end)

    assert :ok = step(newer, fn -> append([event(id, 1)]) end)
    assert :ok = commit(newer)

    assert {:error, %Error{code: :version_mismatch, detail: %{expected: 2, actual: 1}}} =
             step(older, fn -> append([event(id, 2)]) end)

    assert %Postgrex.Result{num_rows: 1} = step(older, fn -> TestRepo.query!("SELECT 1") end)
    assert :ok = commit(older)
    assert versions(id) == [1]
  end

  test "страж xid: транзакция без xid до commit конкурента пишет следующую версию" do
    id = AggID.new()
    older = participant()
    newer = participant()

    assert %Postgrex.Result{} = step(older, fn -> TestRepo.query!("SELECT 1") end)
    assert :ok = step(newer, fn -> append([event(id, 1)]) end)
    assert :ok = commit(newer)

    assert :ok = step(older, fn -> append([event(id, 2)]) end)
    assert :ok = commit(older)
    assert versions(id) == [1, 2]
  end

  # Участник держит свою транзакцию вне sandbox и исполняет присланные шаги по одному,
  # пока не получит `:commit`.
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

  # Запрос участника дошёл до ожидания блокировки: без этого commit конкурента мог бы его
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

  defp append(events) do
    Es.Store.append(@codec, events, Context.new(), &mismatch/1)
  end

  defp mismatch(detail), do: EventFixture.Errors.domain(__MODULE__, :version_mismatch, detail)

  defp event(id, version), do: EventFixture.in_stream(EventFixture.created(), id, version)

  defp versions(id) do
    Sandbox.unboxed_run(TestRepo, fn ->
      @codec
      |> Es.Store.Test.events!(id)
      |> Enum.map(&Version.value(&1.aggregate_version))
    end)
  end
end
