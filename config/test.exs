import Config

# Библиотека выступает собственным потребителем: `otp_app` — она сама.
config :core,
  otp_app: :core,
  dao: Core.TestRepo,
  codec: Core.CodecFixture.Internal,
  # Не UTC: иначе тесты сдвига зон в Prim.Date* и Codec ничего не проверяют.
  tz: "Asia/Vladivostok"

config :core, ecto_repos: [Core.TestRepo]

config :core, Core.TestRepo,
  # Не `priv/test_repo`: миграции здесь — ещё и исполняемая спецификация таблиц
  # Core для приложений-потребителей, путь должен читаться.
  priv: "priv/repo",
  username: "core",
  password: "core",
  hostname: "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5433")),
  database: "core_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg

config :core, Core.Outbox,
  enabled: false,
  poll_interval_ms: 60_000,
  idle_min_ms: 50,
  poller_name: nil,
  cleaner_interval_ms: 86_400_000

config :core, Core.Security.Secret, secret_key: "qI1uzVjrHlMCym8sO62o9uoRdqmqGQf_QmEo4o5uzmE="

config :core, Core.Mq.Stream,
  host: "localhost",
  port: String.to_integer(System.get_env("RABBIT_STREAM_PORT", "5553")),
  vhost: "/",
  username: "guest",
  password: "guest",
  lazy: true

config :argon2_elixir, t_cost: 1, m_cost: 8

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :logger, level: :warning
