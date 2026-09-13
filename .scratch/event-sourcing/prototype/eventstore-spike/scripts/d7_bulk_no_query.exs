alias EventstoreSpike.{H, Repo}
alias EventstoreSpike.EventStore, as: Store

H.start_store!()

IO.puts("== d7: 1000 событий с устаревшей expected_version, без последующих запросов в TX")
s = H.uuid("d7")
:ok = Store.append_to_stream(s, 0, H.events(1))
label = H.uuid("d7")

res =
  try do
    Repo.transaction(fn ->
      H.insert_row(label)
      H.log("append 1000 expected 0", Store.append_to_stream(s, 0, H.events(1000), conn: H.conn()))
      H.log("DBConnection.status", H.status())
      :fun_returned
    end)
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  end

H.log("Repo.transaction", res)
Process.sleep(200)
H.log("строк / версия потока", {H.rows(label), H.stream_version(s)})

IO.puts("\n== d8: то же через Repo.transact с {:error, _}")
label = H.uuid("d8")

res =
  Repo.transact(fn ->
    H.insert_row(label)
    {:error, Store.append_to_stream(s, 0, H.events(1000), conn: H.conn())}
  end)

H.log("Repo.transact", res)
Process.sleep(200)
H.log("строк / версия потока", {H.rows(label), H.stream_version(s)})
