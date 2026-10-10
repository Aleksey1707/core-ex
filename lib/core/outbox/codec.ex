defmodule Core.Outbox.Codec do
  @moduledoc """
  Кодек outbox: `Record` и `RecordError` — по полям (`fields:`).

  `Repo.Pg.Schema` обязан ходить через фасад из `Core.Config.codec/0`.
  Enum-поле `status` кодек не сериализует — атом остаётся как есть.
  """

  use Core.Codec.Plugin,
    types: [
      Core.Outbox.Record,
      Core.Outbox.RecordError
    ],
    fields: [
      {Core.Outbox.Record,
       id: [prim: Core.Outbox.ID],
       topic: [prim: Core.Outbox.Topic],
       key: [prim: Core.Outbox.Key],
       name: [prim: Core.Outbox.Name],
       payload: [type: :map],
       status: [enum: Core.Outbox.Status],
       attempts: [prim: Core.Outbox.Attempts],
       locked_until: [prim: Core.Outbox.LockedUntil, optional: true],
       lease_id: [prim: Core.Outbox.LeaseID, optional: true],
       published_at: [prim: Core.Outbox.PublishedAt, optional: true],
       errors: [list: [entity: Core.Outbox.RecordError], default: []],
       headers: [type: :map, optional: true],
       created_at: [prim: Core.Outbox.CreatedAt],
       updated_at: [prim: Core.Outbox.UpdatedAt, optional: true]},
      {Core.Outbox.RecordError, attempt: [prim: Core.Outbox.Attempt], message: [prim: Core.Outbox.ErrorMessage]}
    ]
end
