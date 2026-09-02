defmodule Core.Outbox.Codec do
  @moduledoc """
  Кодек outbox: `Record` и `RecordError`.

  `Repo.Pg.Schema` обязан ходить через фасад из `Core.Config.codec/0`.
  Enum-поле `status` кодек не сериализует — атом остаётся как есть.
  """

  use Core.Codec.Plugin,
    types: [
      Core.Outbox.Record,
      Core.Outbox.RecordError
    ]

  alias Core.Error
  alias Core.Outbox
  alias Core.Outbox.Record

  @doc "Record/RecordError → map полей."
  @spec dump(Record.t() | Outbox.RecordError.t(), module()) :: map()

  @impl true
  def dump(%Record{} = record, codec) do
    %{
      id: codec.dump(record.id),
      topic: codec.dump(record.topic),
      key: codec.dump(record.key),
      name: codec.dump(record.name),
      payload: record.payload,
      status: record.status,
      attempts: codec.dump(record.attempts),
      locked_until: dump_optional(record.locked_until, codec),
      lease_id: dump_optional(record.lease_id, codec),
      published_at: dump_optional(record.published_at, codec),
      errors: Enum.map(record.errors, &codec.dump/1),
      headers: record.headers,
      created_at: codec.dump(record.created_at),
      updated_at: dump_optional(record.updated_at, codec)
    }
  end

  def dump(%Outbox.RecordError{} = error, codec) do
    %{
      attempt: codec.dump(error.attempt),
      message: codec.dump(error.message)
    }
  end

  @doc "Модуль + map → Record/RecordError."
  @spec load(module(), map(), module()) ::
          {:ok, Record.t() | Outbox.RecordError.t()} | {:error, Error.t()}

  @impl true
  def load(Record, map, codec) when is_map(map) do
    with {:ok, id} <- codec.load(Outbox.ID, field(map, :id)),
         {:ok, topic} <- codec.load(Outbox.Topic, field(map, :topic)),
         {:ok, key} <- codec.load(Outbox.Key, field(map, :key)),
         {:ok, name} <- codec.load(Outbox.Name, field(map, :name)),
         {:ok, status} <- Outbox.Status.cast(field(map, :status)),
         {:ok, attempts} <- codec.load(Outbox.Attempts, field(map, :attempts)),
         {:ok, locked_until} <-
           load_optional(field(map, :locked_until), Outbox.LockedUntil, codec),
         {:ok, lease_id} <- load_optional(field(map, :lease_id), Outbox.LeaseID, codec),
         {:ok, published_at} <-
           load_optional(field(map, :published_at), Outbox.PublishedAt, codec),
         {:ok, errors} <- load_many(Outbox.RecordError, field(map, :errors) || [], codec),
         {:ok, created_at} <- codec.load(Outbox.CreatedAt, field(map, :created_at)),
         {:ok, updated_at} <- load_optional(field(map, :updated_at), Outbox.UpdatedAt, codec) do
      {:ok,
       %Record{
         id: id,
         topic: topic,
         key: key,
         name: name,
         payload: field(map, :payload),
         status: status,
         attempts: attempts,
         locked_until: locked_until,
         lease_id: lease_id,
         published_at: published_at,
         errors: errors,
         headers: field(map, :headers),
         created_at: created_at,
         updated_at: updated_at
       }}
    end
  end

  def load(Outbox.RecordError, map, codec) when is_map(map) do
    with {:ok, attempt} <- codec.load(Outbox.Attempt, field(map, :attempt)),
         {:ok, message} <- codec.load(Outbox.ErrorMessage, field(map, :message)) do
      {:ok, Outbox.RecordError.new(attempt, message)}
    end
  end
end
