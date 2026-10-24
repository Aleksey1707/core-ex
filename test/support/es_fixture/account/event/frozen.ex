defmodule Core.EsFixture.Account.Event.Frozen do
  @moduledoc "Счёт заморожен."

  alias Core.EsFixture.Account

  use Core.Es.Event,
    family: Account.Event,
    payload: nil
end
