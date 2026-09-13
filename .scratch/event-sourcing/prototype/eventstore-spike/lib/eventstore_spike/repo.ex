defmodule EventstoreSpike.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :eventstore_spike, adapter: Ecto.Adapters.Postgres
end

defmodule EventstoreSpike.PublicRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :eventstore_spike, adapter: Ecto.Adapters.Postgres
end
