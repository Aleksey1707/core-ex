alias EventstoreSpike.{H, Repo}
alias EventstoreSpike.EventStore, as: Store

H.start_store!()

IO.puts("== d1: устаревшая expected_version (поток уже версии 1), fun возвращается нормально")
s = H.uuid("d1")
:ok = Store.append_to_stream(s, 0, H.events(1))
label = H.uuid("d1")

res =
  Repo.transaction(fn ->
    H.insert_row(label)
    H.log("append expected 0", Store.append_to_stream(s, 0, H.events(1), conn: H.conn()))
    H.log("DBConnection.status", H.status())
    H.log("следующий запрос в TX", Repo.query("select 1") |> then(fn {tag, r} -> {tag, r.__struct__} end))
    :fun_returned
  end)

H.log("Repo.transaction", res)
H.log("строк / версия потока", {H.rows(label), H.stream_version(s)})

race = fn name, expected_t1, expected_t2, new_stream?, mode ->
  IO.puts("\n== #{name}: гонка, T1 держит TX 1000 мс, T2 (mode=#{mode}) пишет в тот же поток")
  s = H.uuid(name)
  unless new_stream?, do: :ok = Store.append_to_stream(s, 0, H.events(1))
  parent = self()

  t1 =
    Task.async(fn ->
      Repo.transaction(fn ->
        :ok = Store.append_to_stream(s, expected_t1, H.events(1, "t1"), conn: H.conn())
        send(parent, :t1_appended)
        Process.sleep(1000)
        :t1_committed
      end)
    end)

  receive do
    :t1_appended -> :ok
  end

  label = H.uuid(name)
  t0 = System.monotonic_time(:millisecond)

  body = fn ->
    H.insert_row(label)
    r = Store.append_to_stream(s, expected_t2, H.events(1, "t2"), conn: H.conn())
    H.log("T2 append (ждал #{System.monotonic_time(:millisecond) - t0} мс)", r)
    H.log("T2 DBConnection.status", H.status())
    H.try_log("T2 следующий запрос в TX", fn -> Repo.query("select 1") end)
    r
  end

  res =
    try do
      case mode do
        :transaction_ok -> Repo.transaction(fn -> body.() && :fun_returned end)
        :transact_error -> Repo.transact(fn -> {:error, body.()} end)
      end
    rescue
      e -> {:raised, e.__struct__, Exception.message(e)}
    end

  H.log("T1", Task.await(t1))
  H.log("T2 итог транзакции", res)
  H.log("строк T2 / версия потока", {H.rows(label), H.stream_version(s)})
  {:ok, evs} = Store.read_stream_forward(s)
  H.log("события потока", Enum.map(evs, &{&1.stream_version, &1.data.n}))
end

race.("d2", 1, 1, false, :transaction_ok)
race.("d3", 1, 1, false, :transact_error)
race.("d4", 0, :any_version, true, :transaction_ok)

IO.puts("\n== d5: гонка создания потока без внешней TX у T2 (повтор maybe_retry_once на пуле store)")
s = H.uuid("d5")
parent = self()

t1 =
  Task.async(fn ->
    Repo.transaction(fn ->
      :ok = Store.append_to_stream(s, 0, H.events(1, "t1"), conn: H.conn())
      send(parent, :t1_appended)
      Process.sleep(1000)
    end)
  end)

receive do
  :t1_appended -> :ok
end

H.log("T2 append :any_version без TX", Store.append_to_stream(s, :any_version, H.events(1, "t2")))
Task.await(t1)
H.log("версия потока", H.stream_version(s))

IO.puts("\n== d6: 1000 событий с устаревшей expected_version (Postgrex.rollback во вложенной TX)")
s = H.uuid("d6")
:ok = Store.append_to_stream(s, 0, H.events(1))
label = H.uuid("d6")

res =
  try do
    Repo.transaction(fn ->
      H.insert_row(label)
      H.log("append 1000 expected 0", Store.append_to_stream(s, 0, H.events(1000), conn: H.conn()))
      H.log("DBConnection.status", H.status())
      H.try_log("следующий запрос в TX", fn -> Repo.query("select 1") end)
      :fun_returned
    end)
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  end

H.log("Repo.transaction", res)
H.log("строк / версия потока", {H.rows(label), H.stream_version(s)})
