defmodule Consumer.Domain.Sales.Common.Account.Event.Opened do
  alias Consumer.Domain.Sales.Common.Account
  alias Consumer.Domain.Sales.Common.UserID

  defmodule Payload do
    @enforce_keys ~w(name)a
    defstruct @enforce_keys

    def new(%Account.Name{} = name), do: %__MODULE__{name: name}
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload
end
