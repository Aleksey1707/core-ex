alias EventstoreSpike.{H, Repo}
alias EventstoreSpike.EventStore, as: Store

H.start_store!()
H.t0!()

median = fn xs ->
  xs = Enum.sort(xs)
  Enum.at(xs, div(length(xs), 2))
end

:ok = Store.append_to_stream(H.uuid("warm"), 0, H.events(1))

base_no_tx =
  for _ <- 1..30 do
    {us, :ok} = :timer.tc(fn -> Store.append_to_stream(H.uuid("e0"), 0, H.events(1)) end)
    us / 1000
  end

base_tx =
  for _ <- 1..30 do
    {us, {:ok, :ok}} =
      :timer.tc(fn ->
        Repo.transaction(fn -> Store.append_to_stream(H.uuid("e0tx"), 0, H.events(1), conn: H.conn()) end)
      end)

    us / 1000
  end

H.log("базово: append 1 события без TX, медиана мс (30 прогонов)", median.(base_no_tx))
H.log("базово: Repo.transaction + append через conn:, медиана мс (30 прогонов)", median.(base_tx))

scenario = fn mode ->
  IO.puts("\n== #{mode}: T1 append в A и держит TX 2000 мс; T2 после append T1")
  parent = self()

  t1 =
    Task.async(fn ->
      Repo.transaction(fn ->
        :ok = Store.append_to_stream(H.uuid("A"), 0, H.events(1), conn: H.conn())
        send(parent, {:t1_appended, H.t()})
        Process.sleep(2000)
      end)

      H.t()
    end)

  t1_appended =
    receive do
      {:t1_appended, at} -> at
    end

  t2 =
    Task.async(fn ->
      start = H.t()

      r =
        case mode do
          :e1_tx_other_stream ->
            Repo.transaction(fn -> Store.append_to_stream(H.uuid("B"), 0, H.events(1), conn: H.conn()) end)

          :e2_no_tx_other_stream ->
            Store.append_to_stream(H.uuid("B"), 0, H.events(1))

          :e3_existing_stream_no_tx ->
            Store.append_to_stream(Process.get(:existing) || "e3-existing", :any_version, H.events(1))

          :e4_ecto_only_tx ->
            Repo.transaction(fn -> H.insert_row("e4") end) |> elem(0)

          :e5_read_all_no_tx ->
            Store.read_all_streams_backward(-1, 1) |> elem(0)
        end

      {start, H.t(), r}
    end)

  Process.sleep(500)
  H.log("ожидающие блокировку через 500 мс", H.lock_waits())
  t1_commit = Task.await(t1, 10_000)
  {start, done, r} = Task.await(t2, 10_000)

  H.log(
    "T1 append / T2 start / T2 done / T1 commit (мс от старта)",
    {t1_appended, start, done, t1_commit}
  )

  H.log("T2 результат", r)
  H.log("T2 длительность мс; T2 done − T1 commit мс", {done - start, done - t1_commit})
end

:ok = Store.append_to_stream("e3-existing", :any_version, H.events(1))

Enum.each(
  ~w(e1_tx_other_stream e2_no_tx_other_stream e3_existing_stream_no_tx e4_ecto_only_tx e5_read_all_no_tx)a,
  scenario
)
