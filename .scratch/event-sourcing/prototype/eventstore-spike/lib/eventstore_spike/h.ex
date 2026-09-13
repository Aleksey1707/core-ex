defmodule EventstoreSpike.H do
  @moduledoc false

  alias EventstoreSpike.Repo

  def conn do
    %{pid: pool} = Ecto.Adapter.lookup_meta(Repo)
    Process.get({Ecto.Adapters.SQL, pool})
  end

  def events(n, tag \\ "e") do
    for i <- 1..n do
      %EventStore.EventData{data: %EventstoreSpike.Happened{n: "#{tag}-#{i}"}, metadata: %{}}
    end
  end

  def uuid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}"

  def start_store! do
    {:ok, pid} = EventstoreSpike.EventStore.start_link()
    pid
  end

  def insert_row(label), do: Repo.query!("insert into spike_rows(label) values ($1)", [label])

  def rows(label), do: outside(fn -> q("select count(*) from spike_rows where label = $1", [label]) end)

  def all_version, do: outside(fn -> q("select stream_version from event_store.streams where stream_id = 0") end)

  def stream_version(uuid),
    do: outside(fn -> q("select stream_version from event_store.streams where stream_uuid = $1", [uuid]) end)

  def outside(fun), do: fun |> Task.async() |> Task.await(15_000)

  def q(sql, params \\ []) do
    case Repo.query!(sql, params).rows do
      [[v]] -> v
      [] -> nil
      rows -> rows
    end
  end

  def status, do: DBConnection.status(conn())

  def t0!, do: :persistent_term.put(:spike_t0, System.monotonic_time(:millisecond))
  def t, do: System.monotonic_time(:millisecond) - :persistent_term.get(:spike_t0, 0)

  def log(label, value),
    do: IO.puts("#{label}: #{inspect(value, limit: 50, printable_limit: 400, pretty: false)}")

  def try_log(label, fun) do
    log(label, fun.())
  rescue
    e -> log(label, {:raised, e.__struct__, Exception.message(e)})
  catch
    kind, reason -> log(label, {kind, reason})
  end

  def lock_waits do
    outside(fn ->
      q("""
      select a.pid, a.wait_event_type, a.wait_event, l.locktype, l.mode, l.relation::regclass::text,
             left(regexp_replace(a.query, '\\s+', ' ', 'g'), 60)
      from pg_stat_activity a
      left join pg_locks l on l.pid = a.pid and not l.granted
      where a.datname = current_database() and a.wait_event_type = 'Lock'
      """)
    end)
  end
end
