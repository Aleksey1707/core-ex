defmodule Core.EsFixture.Account.Event.Renamed do
  @moduledoc "Счёт переименован."

  alias Core.EsFixture.Account

  defmodule Payload do
    @moduledoc "Нагрузка `Renamed` — по полям: клаузы кодека выводятся."

    use Core.Es.Event.Payload, fields: [name: [prim: Account.Name]]
  end

  use Core.Es.Event,
    family: Account.Event,
    payload: Payload
end
