defmodule Core.EsFixture.Account.Event.HolderSet do
  @moduledoc "Владелец счёта указан: ПДн-значение под ключом субъекта — самого счёта."

  alias Core.EsFixture.Account

  defmodule Payload do
    @moduledoc "Нагрузка `HolderSet` — ПДн-поле с `subject: :aggregate_id`."

    use Core.Es.Event.Payload,
      fields: [holder: [prim: Account.Holder, subject: :aggregate_id]]
  end

  use Core.Es.Event,
    family: Account.Event,
    payload: Payload
end
