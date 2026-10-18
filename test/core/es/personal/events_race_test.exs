defmodule Core.Es.Personal.EventsRaceTest do
  # Участники гонки коммитят по-настоящему (`19-testing.md`, «Гонки транзакций»): отсюда
  # `async: false` и уборка таблиц после теста.
  use ExUnit.Case, async: false

  import Core.EsAggregateRepoContract, only: [execute!: 2, open: 0, write!: 3]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Port
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Helper.Transact
  alias Core.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 5_000

  setup do
    id = Account.ID.new()

    on_exit(fn ->
      unboxed(fn ->
        TestRepo.query!("TRUNCATE es_events, outbox")
        TestRepo.query!("DELETE FROM es_subject_keys WHERE subject = $1", [Config.codec().dump(id)])
      end)
    end)

    %{id: id, state: unboxed(fn -> write!(Account.Repo.Pg, id, [open()]) end)}
  end

  test "уничтожение ждёт commit записи: событие записано, затем читается уничтоженным", %{id: id, state: state} do
    writer = participant()
    destroyer = participant()

    assert :ok = step(writer, fn -> append_holder(state) end)
    backend = backend(destroyer)

    send_step(destroyer, fn -> Personal.destroy_key(id, UserID.new(), Context.new()) end)
    await_lock_wait(backend)
    assert {:ok, :ok} = commit(writer)

    assert :ok = await_step(destroyer)
    assert {:ok, :ok} = commit(destroyer)

    assert [_opened, %Account.Event.HolderSet{payload: %{holder: %Destroyed{}}}] =
             unboxed(fn -> Es.Store.Test.events!(Account.Event.Codec, id) end)
  end

  test "запись ждёт commit уничтожения — :subject_destroyed, события нет", %{id: id, state: state} do
    {:ok, [_sealed]} = unboxed(fn -> Port.seal([{Config.codec().dump(id), "aad", "Иван"}]) end)
    destroyer = participant()
    writer = participant()

    assert :ok = step(destroyer, fn -> Personal.destroy_key(id, UserID.new(), Context.new()) end)
    backend = backend(writer)

    send_step(writer, fn -> append_holder(state) end)
    await_lock_wait(backend)
    assert {:ok, :ok} = commit(destroyer)

    assert {:error, %Error{code: :subject_destroyed}} = await_step(writer)
    assert {:error, :rollback} = commit(writer)
    assert [_opened] = unboxed(fn -> Es.Store.Test.events!(Account.Event.Codec, id) end)
  end

  # ---

  defp append_holder(state) do
    command = %Account.Cmd.SetHolder{
      holder: Account.Holder.new!("Иван Петров"),
      by: UserID.new(),
      at: Es.Event.At.now!()
    }

    {events, _state} = execute!(state, command)

    Account.Repo.Pg.append(events, Context.new())
  end

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
        {:ok, :ok}
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

  defp backend(participant) do
    [[backend]] = step(participant, fn -> TestRepo.query!("SELECT pg_backend_pid()").rows end)
    backend
  end

  # Запрос участника дошёл до ожидания блокировки: без этого commit конкурента мог бы его опередить.
  defp await_lock_wait(backend), do: unboxed(fn -> poll_lock_wait(backend) end)

  defp poll_lock_wait(backend) do
    case TestRepo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]) do
      %Postgrex.Result{rows: [["Lock"]]} -> :ok
      %Postgrex.Result{} -> poll_lock_wait(backend)
    end
  end

  defp commit(%Task{pid: pid} = participant) do
    send(pid, :commit)
    Task.await(participant, @timeout)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(TestRepo, fun)
end
