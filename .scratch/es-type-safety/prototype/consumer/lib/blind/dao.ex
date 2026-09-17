defmodule Blind.DAO do
  use Core.DAO,
    otp_app: :blind,
    adapter: Ecto.Adapters.Postgres
end
