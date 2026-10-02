defmodule Consumer.Infra.DAO do
  use Core.DAO,
    otp_app: :consumer,
    adapter: Ecto.Adapters.Postgres
end
