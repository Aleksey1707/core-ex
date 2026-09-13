alias EventstoreSpike.{H, Repo}
alias EventstoreSpike.EventStore, as: Store

H.log("OTP-приложение :eventstore запущено", List.keymember?(Application.started_applications(), :eventstore, 0))
H.log("процесс EventstoreSpike.EventStore", Process.whereis(Store))
H.try_log("Store.config() без запуска", fn -> Keyword.take(Store.config(), [:schema, :serializer, :pool_size]) end)

s = H.uuid("g1")
label = H.uuid("g1")

res =
  Repo.transaction(fn ->
    H.insert_row(label)
    H.try_log("append_to_stream с conn: без запущенного store", fn ->
      Store.append_to_stream(s, 0, H.events(1), conn: H.conn())
    end)

    H.try_log("read_stream_forward с conn:", fn -> Store.read_stream_forward(s, 0, 10, conn: H.conn()) end)
    H.try_log("stream_info с conn:", fn -> Store.stream_info(s, conn: H.conn()) end)
    H.log("DBConnection.status после исключений", H.status())

    H.try_log("внутренний EventStore.Streams.Stream.append_to_stream (@moduledoc false)", fn ->
      EventStore.Streams.Stream.append_to_stream(H.conn(), s, 0, H.events(1),
        schema: "event_store",
        serializer: EventStore.JsonSerializer
      )
    end)

    :done
  end)

H.log("Repo.transaction", res)
H.log("строк / версия потока", {H.rows(label), H.stream_version(s)})
