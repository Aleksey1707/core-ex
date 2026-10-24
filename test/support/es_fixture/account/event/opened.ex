defmodule Core.EsFixture.Account.Event.Opened do
  @moduledoc "Счёт открыт."

  alias Core.EsFixture.Account

  defmodule Payload do
    @moduledoc "Нагрузка `Opened`."

    use Core.Es.Event.Payload,
      fields: [name: [prim: Account.Name]]
  end

  use Core.Es.Event,
    family: Account.Event,
    payload: Payload
end
