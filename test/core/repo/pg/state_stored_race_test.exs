defmodule Core.Repo.Pg.StateStoredRaceTest do
  # Участники гонки коммитят по-настоящему: sandbox-транзакция теста одна на всех и
  # конкурентной записи не даёт. Отсюда `async: false` и очистка таблиц после теста.
  use ExUnit.Case, async: false

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.Helper.Transact
  alias Core.StateStoredFixture
  alias Core.StateStoredFixture.Entity
  alias Core.TestRepo
  alias Core.Version
  alias Ecto.Adapters.SQL.Sandbox

  require Config

  @codec EventFixture.Event.Codec
  @repo Config.repo!(StateStoredFixture.Repo)
  @timeout 5_000

  setup do
    on_exit(fn ->
      Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!("TRUNCATE es_events, outbox, fixture_entities CASCADE")
      end)
    end)
  end

  test "страж xid: транзакция получила xid до commit конкурента — :version_mismatch write-репозитория" do
    id = AggID.new()
    assert {:ok, _} = unboxed(fn -> @repo.insert(entity(id, 1), Context.new()) end)

    older = participant()
    newer = participant()

    assert %Postgrex.Result{} =
             step(older, fn -> TestRepo.query!("SELECT pg_current_xact_id()") end)

    assert {:ok, _} = step(newer, fn -> @repo.update(entity(id, 2), Context.new()) end)
    assert :ok = commit(newer)

    assert {:error, %Error{module: StateStoredFixture.Repo, code: :version_mismatch} = error} =
             step(older, fn -> @repo.update(entity(id, 3), Context.new()) end)

    assert error.detail == %{
             aggregate_id: Config.codec().dump(id),
             expected: 3,
             actual: 2,
             source: :storage
           }

    assert {:error, :rollback} = commit(older)

    assert {:ok, %Entity{version: version}} =
             unboxed(fn -> @repo.get(id, :current, Context.new()) end)

    assert Version.value(version) == 2
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

  defp step(%Task{pid: pid}, fun) do
    send(pid, {:step, fun})
    assert_receive {:step, ^pid, result}, @timeout
    result
  end

  defp commit(%Task{pid: pid} = participant) do
    send(pid, :commit)
    Task.await(participant, @timeout)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(TestRepo, fun)

  defp entity(id, version) do
    %Entity{
      id: id,
      version: Version.new!(version),
      name: "Приёмка",
      children: %{},
      events: Es.Events.new([EventFixture.in_stream(EventFixture.created(), id, version)])
    }
  end

  defp versions(id) do
    unboxed(fn ->
      @codec
      |> Es.Store.Test.events!(id)
      |> Enum.map(&Version.value(&1.aggregate_version))
    end)
  end
end
