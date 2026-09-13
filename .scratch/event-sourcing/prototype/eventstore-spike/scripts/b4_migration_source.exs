alias EventstoreSpike.PublicRepo

IO.puts("== b4: EventStore в public уже есть; Ecto с migration_source: \"ecto_schema_migrations\"")

Application.put_env(
  :eventstore_spike,
  PublicRepo,
  Keyword.put(Application.get_env(:eventstore_spike, PublicRepo), :migration_source, "ecto_schema_migrations")
)

path = Path.expand("priv/repo/migrations")

result =
  try do
    Ecto.Migrator.with_repo(PublicRepo, &Ecto.Migrator.run(&1, path, :up, all: true, log: false))
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  end

IO.puts("Ecto.Migrator.run: #{inspect(result)}")

{:ok, conn} =
  Postgrex.start_link(
    Application.get_env(:eventstore_spike, PublicRepo)
    |> Keyword.take([:username, :password, :hostname, :port, :database])
  )

%{rows: rows} =
  Postgrex.query!(conn, "select table_name from information_schema.tables where table_schema = 'public' order by 1", [])

IO.puts("таблицы public: #{inspect(List.flatten(rows))}")
