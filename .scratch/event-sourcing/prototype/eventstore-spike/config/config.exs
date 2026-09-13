import Config

db = [
  username: "core",
  password: "core",
  hostname: "localhost",
  port: 5433,
  database: "eventstore_spike_prototype_wipe_me"
]

config :eventstore_spike,
  ecto_repos: [EventstoreSpike.Repo],
  event_stores: [EventstoreSpike.EventStore]

config :eventstore_spike, EventstoreSpike.Repo, db ++ [pool_size: 5]

config :eventstore_spike,
       EventstoreSpike.EventStore,
       db ++ [serializer: EventStore.JsonSerializer, schema: "event_store", pool_size: 5]

config :eventstore_spike,
       EventstoreSpike.PublicStore,
       Keyword.put(db, :database, "eventstore_spike_public_prototype_wipe_me") ++
         [serializer: EventStore.JsonSerializer, pool_size: 2]

config :eventstore_spike,
       EventstoreSpike.PublicRepo,
       Keyword.put(db, :database, "eventstore_spike_public_prototype_wipe_me") ++
         [pool_size: 2, priv: "priv/repo"]

config :logger, level: :info
