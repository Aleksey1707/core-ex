alias EventstoreSpike.{H, Repo}
alias EventstoreSpike.EventStore, as: Store

H.start_store!()

IO.puts("== c0: способ получить соединение")
Repo.transaction(fn ->
  conn = H.conn()
  H.log("conn внутри Repo.transaction", conn)
  H.log("DBConnection.status", H.status())
end)

H.log("conn из pdict вне транзакции", H.conn())

Repo.checkout(fn ->
  H.log("conn внутри Repo.checkout (без TX)", H.conn())
  H.log("DBConnection.status в checkout", H.status())
end)

IO.puts("\n== c1: commit — строка Ecto + 2 события через conn:")
label = H.uuid("c1")
s = H.uuid("c1-stream")
all_before = H.all_version()

res =
  Repo.transaction(fn ->
    H.insert_row(label)
    H.log("append", Store.append_to_stream(s, 0, H.events(2), conn: H.conn()))
    H.log("до commit, извне: строк / версия потока / $all", {H.rows(label), H.stream_version(s), H.all_version()})
    H.log("до commit, в той же TX: read_stream_forward", Store.read_stream_forward(s, 0, 10, conn: H.conn()) |> elem(0))
    :done
  end)

H.log("Repo.transaction", res)
H.log("после: строк / версия потока / $all до→после", {H.rows(label), H.stream_version(s), all_before, H.all_version()})
{:ok, evs} = Store.read_stream_forward(s)
H.log("после: read_stream_forward", Enum.map(evs, &{&1.stream_version, &1.event_number, &1.data}))

IO.puts("\n== c2: Repo.rollback после append")
label = H.uuid("c2")
s = H.uuid("c2-stream")
all_before = H.all_version()

res =
  Repo.transaction(fn ->
    H.insert_row(label)
    H.log("append", Store.append_to_stream(s, 0, H.events(2), conn: H.conn()))
    Repo.rollback(:boom)
  end)

H.log("Repo.transaction", res)
H.log("после: строк / версия потока / $all до→после", {H.rows(label), H.stream_version(s), all_before, H.all_version()})
H.log("read_stream_forward", Store.read_stream_forward(s))

IO.puts("\n== c3: Repo.transact (как Transact.run) — fun вернул {:error, _} после append")
label = H.uuid("c3")
s = H.uuid("c3-stream")
all_before = H.all_version()

res =
  Repo.transact(fn ->
    H.insert_row(label)
    H.log("append", Store.append_to_stream(s, 0, H.events(1), conn: H.conn()))
    {:error, :usecase_failed}
  end)

H.log("Repo.transact", res)
H.log("после: строк / версия потока / $all до→после", {H.rows(label), H.stream_version(s), all_before, H.all_version()})

IO.puts("\n== c4: 1000 событий (ветка Postgrex.transaction внутри внешней TX) + Repo.rollback")
label = H.uuid("c4")
s = H.uuid("c4-stream")
all_before = H.all_version()

res =
  Repo.transaction(fn ->
    H.insert_row(label)
    H.log("append 1000", Store.append_to_stream(s, 0, H.events(1000), conn: H.conn()))
    H.log("status после append 1000", H.status())
    Repo.rollback(:boom)
  end)

H.log("Repo.transaction", res)
H.log("после: строк / версия потока / $all до→после", {H.rows(label), H.stream_version(s), all_before, H.all_version()})

IO.puts("\n== c5: 1000 событий + commit")
label = H.uuid("c5")
s = H.uuid("c5-stream")

res =
  Repo.transaction(fn ->
    H.insert_row(label)
    H.log("append 1000", Store.append_to_stream(s, 0, H.events(1000), conn: H.conn()))
    H.log("insert после append 1000", H.insert_row(label <> "-2").num_rows)
    :done
  end)

H.log("Repo.transaction", res)
H.log("после: строк / версия потока", {H.rows(label), H.rows(label <> "-2"), H.stream_version(s)})

IO.puts("\n== c6: conn: из pdict вне транзакции (nil) — куда уходит append")
s = H.uuid("c6-stream")
conn = H.conn()
H.log("conn", conn)
H.log("append conn: nil", Store.append_to_stream(s, 0, H.events(1), conn: conn))
H.log("версия потока", H.stream_version(s))
