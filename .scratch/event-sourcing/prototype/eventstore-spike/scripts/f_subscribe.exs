alias EventstoreSpike.{H, Repo}
alias EventstoreSpike.EventStore, as: Store

H.start_store!()
H.t0!()
parent = self()

forwarder = fn tag, subscribe ->
  spawn_link(fn ->
    subscribe.(self())

    loop = fn loop ->
      receive do
        {:subscribed, sub} ->
          Process.put(:sub, sub)
          send(parent, {tag, :subscribed})

        {:events, evs} ->
          send(parent, {tag, H.t(), Enum.map(evs, &{&1.stream_uuid, &1.stream_version, &1.event_number})})
          if sub = Process.get(:sub), do: Store.ack(sub, evs)
      end

      loop.(loop)
    end

    loop.(loop)
  end)
end

forwarder.(:persistent, fn pid ->
  {:ok, _} = Store.subscribe_to_all_streams(H.uuid("f-sub"), pid, start_from: :current)
end)

forwarder.(:transient, fn _pid -> :ok = Store.subscribe("$all") end)

receive do
  {:persistent, :subscribed} -> H.log("persistent подписка", :subscribed)
after
  5000 -> H.log("persistent подписка", :timeout)
end

drain = fn ms ->
  deadline = H.t() + ms

  Stream.repeatedly(fn ->
    receive do
      {tag, at, evs} when tag in [:persistent, :transient] -> {tag, at, evs}
    after
      max(deadline - H.t(), 0) -> :done
    end
  end)
  |> Enum.take_while(&(&1 != :done))
end

IO.puts("== f1: append через conn: внутри TX, 1000 мс ожидания внутри TX, затем commit")
s = H.uuid("f1")

Repo.transaction(fn ->
  :ok = Store.append_to_stream(s, 0, H.events(2, "f1"), conn: H.conn())
  H.log("append в TX (мс от старта)", H.t())
  H.log("получено до commit за 1000 мс", drain.(1000))
end)

H.log("commit (мс от старта)", H.t())
H.log("получено после commit (ожидание 2000 мс)", drain.(2000))

IO.puts("\n== f2: append через conn: + Repo.rollback")
s = H.uuid("f2")

Repo.transaction(fn ->
  :ok = Store.append_to_stream(s, 0, H.events(2, "f2"), conn: H.conn())
  Repo.rollback(:boom)
end)

H.log("rollback (мс от старта)", H.t())
H.log("получено после rollback (ожидание 1500 мс)", drain.(1500))

IO.puts("\n== f3: следующий committed append — нумерация $all после отката")
s = H.uuid("f3")
{:ok, :ok} = Repo.transaction(fn -> Store.append_to_stream(s, 0, H.events(1, "f3"), conn: H.conn()) end)
H.log("commit (мс от старта)", H.t())
H.log("получено", drain.(2000))

IO.puts("\n== f4: append без внешней TX (базово)")
s = H.uuid("f4")
:ok = Store.append_to_stream(s, 0, H.events(1, "f4"))
H.log("append вернул (мс от старта)", H.t())
H.log("получено", drain.(2000))
