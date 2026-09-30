defmodule Core.Mq.Dlq.Store do
  @moduledoc """
  Строки `mq_dlq` для `Core.Mq.Dlq.Writer` и `Core.Mq.Dlq.Reader` (`Core.Mq.Dlq.Migration`).

  Запись `requeued` читатель захватывает fencing-токеном `lease_id` на срок `locked_until`
  (часы Postgres): две ноды с читателем одного топика не отдают одну запись обеим. Захват
  пропускает строки, заблокированные чужой транзакцией (`SKIP LOCKED`), и записи с живым
  захватом. `commit/3` проходит только у владельца токена: запись, которую после истечения
  срока перехватила другая нода, устаревшей ноде не закоммитить.

  Сбой Postgres — исключение `Ecto`: вызывающий ловит его сам.
  """

  alias Core.Error

  require Error

  @insert_sql "INSERT INTO mq_dlq (subscriber_name, topic, key, header_names, header_values, body, " <>
                "source_partition, source_offset, reason, error, attempts, status, created_at) " <>
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'dead', clock_timestamp())"

  @claim_sql "UPDATE mq_dlq SET lease_id = $3, " <>
               "locked_until = clock_timestamp() + $4::integer * interval '1 millisecond' " <>
               "WHERE id = (SELECT id FROM mq_dlq WHERE subscriber_name = $1 AND topic = $2 " <>
               "AND status = 'requeued' AND (locked_until IS NULL OR locked_until <= clock_timestamp()) " <>
               "ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED) " <>
               "RETURNING id, key, header_names, header_values, body, source_partition, source_offset"

  @hold_sql "UPDATE mq_dlq SET locked_until = clock_timestamp() + $3::integer * interval '1 millisecond' " <>
              "WHERE id = $1 AND lease_id = $2 AND status = 'requeued'"

  @release_sql "UPDATE mq_dlq SET locked_until = clock_timestamp() " <>
                 "WHERE id = $1 AND lease_id = $2 AND status = 'requeued'"

  @commit_sql "UPDATE mq_dlq SET status = 'processed', processed_at = clock_timestamp(), " <>
                "lease_id = NULL, locked_until = NULL WHERE id = $1 AND lease_id = $2 AND status = 'requeued'"

  @typedoc "Fencing-токен захвата — UUID в 16 байтах."
  @type lease :: <<_::128>>

  @typedoc "Строка на запись: заголовки — пары по индексу, позиция — `nil`, если её нет."
  @type row :: %{
          subscriber: String.t(),
          topic: String.t(),
          key: binary() | nil,
          header_names: [String.t()],
          header_values: [binary()],
          body: binary() | nil,
          partition: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          reason: String.t() | nil,
          error: String.t() | nil,
          attempts: non_neg_integer() | nil
        }

  @typedoc "Захваченная запись."
  @type claimed :: %{
          id: pos_integer(),
          key: binary() | nil,
          header_names: [String.t()],
          header_values: [binary()],
          body: binary() | nil,
          partition: non_neg_integer() | nil,
          offset: non_neg_integer() | nil
        }

  # ===== запись =====

  @doc "Записать выброшенное сообщение строкой `dead`."
  @spec insert(Ecto.Repo.t(), row()) :: :ok

  def insert(repo, %{subscriber: subscriber, topic: topic} = row)
      when is_atom(repo) and is_binary(subscriber) and is_binary(topic) do
    params = [
      subscriber,
      topic,
      row.key,
      row.header_names,
      row.header_values,
      row.body,
      row.partition,
      row.offset,
      row.reason,
      row.error,
      row.attempts
    ]

    _ = Ecto.Adapters.SQL.query!(repo, @insert_sql, params)
    :ok
  end

  # ===== чтение =====

  @doc "Новый fencing-токен: читатель захватывает им записи."
  @spec new_lease() :: lease()

  def new_lease, do: Ecto.UUID.bingenerate()

  @doc "Захватить старейшую свободную запись `requeued` топика подписчика на `ttl_ms`."
  @spec claim(Ecto.Repo.t(), String.t(), String.t(), lease(), pos_integer()) :: {:ok, claimed()} | :none

  def claim(repo, subscriber, topic, <<_::128>> = lease, ttl_ms)
      when is_atom(repo) and is_binary(subscriber) and is_binary(topic) and is_integer(ttl_ms) and ttl_ms > 0 do
    case Ecto.Adapters.SQL.query!(repo, @claim_sql, [subscriber, topic, lease, ttl_ms]) do
      %{rows: [[id, key, names, values, body, partition, offset]]} ->
        {:ok,
         %{
           id: id,
           key: key,
           header_names: names,
           header_values: values,
           body: body,
           partition: partition,
           offset: offset
         }}

      %{rows: []} ->
        :none
    end
  end

  @doc "Продлить свой захват записи; `:lost` — запись перехвачена или уже не `requeued`."
  @spec hold(Ecto.Repo.t(), pos_integer(), lease(), pos_integer()) :: :ok | :lost

  def hold(repo, id, <<_::128>> = lease, ttl_ms)
      when is_atom(repo) and is_integer(id) and is_integer(ttl_ms) and ttl_ms > 0 do
    case Ecto.Adapters.SQL.query!(repo, @hold_sql, [id, lease, ttl_ms]) do
      %{num_rows: 1} -> :ok
      %{num_rows: 0} -> :lost
    end
  end

  @doc "Отдать захват сразу: запись берёт следующий читатель, не дожидаясь срока."
  @spec release(Ecto.Repo.t(), pos_integer(), lease()) :: :ok

  def release(repo, id, <<_::128>> = lease) when is_atom(repo) and is_integer(id) do
    _ = Ecto.Adapters.SQL.query!(repo, @release_sql, [id, lease])
    :ok
  end

  @doc """
  Пометить захваченную запись `processed`.

  `{:error, %Error{code: :dlq_lease_lost}}` — запись перехвачена другим токеном или уже не
  `requeued`, статус не изменён.
  """
  @spec commit(Ecto.Repo.t(), pos_integer(), lease()) :: :ok | {:error, Error.t()}

  def commit(repo, id, <<_::128>> = lease) when is_atom(repo) and is_integer(id) do
    case Ecto.Adapters.SQL.query!(repo, @commit_sql, [id, lease]) do
      %{num_rows: 1} ->
        :ok

      %{num_rows: 0} ->
        {:error,
         Error.app(
           code: :dlq_lease_lost,
           ns: :mq,
           message: "Захват записи DLQ потерян: запись не помечена обработанной",
           detail: %{id: id}
         )}
    end
  end
end
