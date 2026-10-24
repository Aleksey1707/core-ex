defmodule Core.EsFixture.Account.Event.Verified do
  @moduledoc "Счёт проверен. Тип удалён: событие больше не пишется."

  alias Core.EsFixture.Account

  use Core.Es.Event,
    family: Account.Event,
    payload: nil
end
