import Config

config :core,
  otp_app: :consumer,
  dao: Consumer.Infra.DAO,
  codec: Consumer.Codec.Internal

config :consumer, Consumer.Infra.DAO,
  database: "consumer_fixture_nonexistent",
  hostname: "localhost"

config :logger, level: :warning
