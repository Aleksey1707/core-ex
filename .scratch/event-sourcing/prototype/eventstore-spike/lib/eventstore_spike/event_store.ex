defmodule EventstoreSpike.EventStore do
  @moduledoc false
  use EventStore, otp_app: :eventstore_spike
end

defmodule EventstoreSpike.PublicStore do
  @moduledoc false
  use EventStore, otp_app: :eventstore_spike
end

defmodule EventstoreSpike.Happened do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:n]
end
