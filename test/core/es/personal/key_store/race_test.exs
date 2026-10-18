defmodule Core.Es.Personal.KeyStore.RaceTest do
  # Участники гонки коммитят по-настоящему (`19-testing.md`, «Гонки транзакций»): отсюда
  # `async: false` и уборка строк ключей после теста.
  use ExUnit.Case, async: false

  alias Core.Error
  alias Core.Es.Personal.KeyStore.Pg
  alias Core.Helper.Transact
  alias Core.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 5_000

  # Последовательное чтение отдаёт строки в порядке кучи — такой план планировщик может выбрать и сам.
  @seq_scan_only "SELECT set_config('enable_indexscan', 'off', true), " <>
                   "set_config('enable_bitmapscan', 'off', true)"

  setup do
    subject = Ecto.UUID.generate()

    on_exit(fn ->
      Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!("DELETE FROM es_subject_keys WHERE subject = $1", [subject])
      end)
    end)

    %{subject: subject}
  end

  test "ключ одного субъекта создают две транзакции: второй ждёт commit первого, ключ один", %{subject: subject} do
    first = participant()
    second = participant()

    assert {:ok, [sealed_first]} = step(first, fn -> Pg.seal([{subject, "aad", "Иван"}]) end)
    backend = backend(second)

    send_step(second, fn -> Pg.seal([{subject, "aad", "Пётр"}]) end)
    await_lock_wait(backend)
    assert {:ok, :ok} = commit(first)

    assert {:ok, [sealed_second]} = await_step(second)
    assert {:ok, :ok} = commit(second)

    assert {:ok, [{:ok, "Иван"}, {:ok, "Пётр"}]} =
             unboxed(fn -> Pg.open([{sealed_first, "aad"}, {sealed_second, "aad"}]) end)

    assert %Postgrex.Result{rows: [[1]]} =
             unboxed(fn -> TestRepo.query!("SELECT count(*) FROM es_subject_keys WHERE subject = $1", [subject]) end)
  end

  test "зашифрованное до commit уничтожения читается как :destroyed", %{subject: subject} do
    writer = participant()
    destroyer = participant()

    assert {:ok, [sealed]} = step(writer, fn -> Pg.seal([{subject, "aad", "Иван"}]) end)
    backend = backend(destroyer)

    send_step(destroyer, fn -> Pg.destroy(subject) end)
    await_lock_wait(backend)
    assert {:ok, :ok} = commit(writer)

    assert :ok = await_step(destroyer)
    assert {:ok, :ok} = commit(destroyer)

    assert {:ok, [:destroyed]} = unboxed(fn -> Pg.open([{sealed, "aad"}]) end)
  end

  test "запись, ждавшая commit уничтожения, — :subject_destroyed", %{subject: subject} do
    {:ok, [_sealed]} = unboxed(fn -> Pg.seal([{subject, "aad", "Иван"}]) end)
    destroyer = participant()
    writer = participant()

    assert :ok = step(destroyer, fn -> Pg.destroy(subject) end)
    backend = backend(writer)

    send_step(writer, fn -> Pg.seal([{subject, "aad", "Пётр"}]) end)
    await_lock_wait(backend)
    assert {:ok, :ok} = commit(destroyer)

    assert {:error, %Error{code: :subject_destroyed}} = await_step(writer)
    assert {:ok, :ok} = commit(writer)
  end

  test "запись пачки и уничтожение её субъектов в порядке дампа не ловят взаимную блокировку" do
    {lo, hi} = keys_in_heap_order_against_sort(3)
    destroyer = participant()
    writer = participant()

    assert :ok = step(destroyer, fn -> Pg.destroy(lo) end)
    backend = backend(writer)
    assert %Postgrex.Result{} = step(writer, fn -> TestRepo.query!(@seq_scan_only) end)

    send_step(writer, fn -> Pg.seal([{hi, "aad", "Иван"}, {lo, "aad", "Пётр"}]) end)
    await_lock_wait(backend)

    assert :ok = step(destroyer, fn -> Pg.destroy(hi) end)
    assert {:ok, :ok} = commit(destroyer)

    assert {:error, %Error{code: :subject_destroyed}} = await_step(writer)
    assert {:ok, :ok} = commit(writer)
  end

  # ---

  # Ключи двух субъектов, у которых порядок строк в куче обратен порядку дампа: без сортировки
  # последовательное чтение блокировало бы их в порядке кучи.
  defp keys_in_heap_order_against_sort(attempts) when attempts > 0 do
    lo = "0" <> binary_part(Ecto.UUID.generate(), 1, 35)
    hi = "f" <> binary_part(Ecto.UUID.generate(), 1, 35)
    on_exit(fn -> delete_keys([lo, hi]) end)

    case unboxed(fn -> create_keys([hi, lo]) end) do
      [^hi, ^lo] -> {lo, hi}
      _other -> keys_in_heap_order_against_sort(attempts - 1)
    end
  end

  defp create_keys(subjects) do
    {:ok, rows} =
      Transact.run(TestRepo, fn ->
        Enum.each(subjects, &({:ok, [_sealed]} = Pg.seal([{&1, "aad", "Иван"}])))
        sql = "SELECT subject FROM es_subject_keys WHERE subject = ANY($1) ORDER BY ctid"

        {:ok, TestRepo.query!(sql, [subjects]).rows}
      end)

    List.flatten(rows)
  end

  defp delete_keys(subjects),
    do: unboxed(fn -> TestRepo.query!("DELETE FROM es_subject_keys WHERE subject = ANY($1)", [subjects]) end)

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
