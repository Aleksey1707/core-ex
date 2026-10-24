defmodule Core.EsFixture.Account.Event.Closed do
  @moduledoc "Счёт закрыт."

  alias Core.EsFixture.Account

  use Core.Es.Event,
    family: Account.Event,
    payload: nil
end
