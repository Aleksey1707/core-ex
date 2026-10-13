defmodule Consumer.Domain.Sales.Account.Event.Opened do
  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID

  defmodule Payload do
    @enforce_keys ~w(name)a
    defstruct @enforce_keys

    def new(%Account.Name{} = name), do: %__MODULE__{name: name}

    use Core.Labels.Fields,
      fields: [name: [prim: Account.Name]],
      labels: [name: "Название"]
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload

  use Core.Labels.Event, title: "Счёт открыт"
end
