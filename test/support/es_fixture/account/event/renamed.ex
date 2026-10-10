defmodule Core.EsFixture.Account.Event.Renamed do
  @moduledoc "Счёт переименован."

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  defmodule Payload do
    @moduledoc "Нагрузка `Renamed` — по полям: клаузы кодека выводятся."

    use Core.Es.Event.Payload, fields: [name: [prim: Account.Name]]
  end

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: Payload
end
