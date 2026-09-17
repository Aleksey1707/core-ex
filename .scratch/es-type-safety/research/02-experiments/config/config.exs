import Config

config :core,
  otp_app: :blind,
  dao: Blind.DAO,
  codec: Blind.Codec.Internal

config :blind, Blind.DAO,
  database: "blind_nonexistent",
  hostname: "localhost"

config :logger, level: :warning
