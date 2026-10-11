defmodule Core.EsFixture.Account.Event.Opened do
  @moduledoc "Счёт открыт."

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  defmodule Payload do
    @moduledoc "Нагрузка `Opened`."

    use Core.Es.Event.Payload,
      fields: [name: [prim: Account.Name]]
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload
end
