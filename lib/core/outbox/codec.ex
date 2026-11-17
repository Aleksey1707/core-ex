defmodule Core.Outbox.Codec do
  @moduledoc """
  Кодек outbox: `Record` и `RecordError` — декларативные типы (`use Core.Struct`).

  `Repo.Pg.Schema` обязан ходить через фасад из `Core.Config.codec/0`.
  Enum-поле `status` кодек не сериализует — атом остаётся как есть.
  """

  use Core.Codec.Plugin,
    types: [Core.Outbox.Record, Core.Outbox.RecordError]
end
