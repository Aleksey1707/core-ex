import Config

config :core,
  otp_app: :consumer,
  dao: Consumer.DAO,
  codec: Consumer.Codec.Internal

config :consumer, Consumer.DAO,
  database: "consumer_fixture_nonexistent",
  hostname: "localhost"

config :logger, level: :warning
