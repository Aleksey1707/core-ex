defmodule Core.Mq.Kafka.Reader.Store do
  @moduledoc """
  Смещения и аренда `Core.Mq.Kafka.Reader` в Postgres потребителя (`Core.Mq.Kafka.Migration`).

  Аренда — строка на пару `(subscriber_name, topic)` с fencing-токеном `lease_id`, по образцу
  поллера outbox (ADR-0033): топик читает одна нода. Срок аренды считают часы Postgres
  (`clock_timestamp()`), а не часы нод: расхождение часов между нодами не даёт двух владельцев.

  `commit/6` пишет смещение только под живой арендой своего токена, и строка аренды
  блокируется на чтение до конца записи: перехват аренды другой нодой либо ждёт её, либо
  отказывает ей. Устаревшая нода получает `{:error, _}` и сообщение повторит новый владелец.

  Сбой Postgres — исключение `Ecto`: вызывающий (`Kafka.Reader`) ловит его сам.
  """

  alias Core.Error

  require Error

  @acquire_sql "INSERT INTO mq_kafka_leases AS l (subscriber_name, topic, lease_id, locked_until, updated_at) " <>
                 "VALUES ($1, $2, $3, clock_timestamp() + $4::integer * interval '1 millisecond', " <>
                 "clock_timestamp()) " <>
                 "ON CONFLICT (subscriber_name, topic) DO UPDATE SET lease_id = EXCLUDED.lease_id, " <>
                 "locked_until = EXCLUDED.locked_until, updated_at = EXCLUDED.updated_at " <>
                 "WHERE l.lease_id = EXCLUDED.lease_id OR l.locked_until <= clock_timestamp()"

  @release_sql "UPDATE mq_kafka_leases SET locked_until = clock_timestamp(), updated_at = clock_timestamp() " <>
                 "WHERE subscriber_name = $1 AND topic = $2 AND lease_id = $3"

  @commit_sql "INSERT INTO mq_kafka_offsets (subscriber_name, topic, partition, next_offset, updated_at) " <>
                "SELECT l.subscriber_name, l.topic, $3, $4, clock_timestamp() FROM mq_kafka_leases l " <>
                "WHERE l.subscriber_name = $1 AND l.topic = $2 AND l.lease_id = $5 " <>
                "AND l.locked_until > clock_timestamp() FOR SHARE " <>
                "ON CONFLICT (subscriber_name, topic, partition) DO UPDATE " <>
                "SET next_offset = EXCLUDED.next_offset, updated_at = EXCLUDED.updated_at"

  @offsets_sql "SELECT partition, next_offset FROM mq_kafka_offsets WHERE subscriber_name = $1 AND topic = $2"

  @typedoc "Fencing-токен аренды — UUID в 16 байтах."
  @type lease :: <<_::128>>

  # ===== аренда =====

  @doc "Новый fencing-токен: нода берёт им аренду, которой не владеет."
  @spec new_lease() :: lease()

  def new_lease, do: Ecto.UUID.bingenerate()

  @doc """
  Взять аренду токеном `lease` или продлить её на `ttl_ms`.

  `:taken` — аренда жива у другого токена. Свою аренду токен продлевает и после истечения
  срока, если её никто не перехватил: исключительность владения при этом не прерывалась.
  """
  @spec acquire(Ecto.Repo.t(), String.t(), String.t(), lease(), pos_integer()) :: :ok | :taken

  def acquire(repo, subscriber, topic, <<_::128>> = lease, ttl_ms)
      when is_atom(repo) and is_binary(subscriber) and is_binary(topic) and is_integer(ttl_ms) and ttl_ms > 0 do
    case Ecto.Adapters.SQL.query!(repo, @acquire_sql, [subscriber, topic, lease, ttl_ms]) do
      %{num_rows: 1} -> :ok
      %{num_rows: 0} -> :taken
    end
  end

  @doc "Отдать аренду сразу: следующая нода берёт её, не дожидаясь срока. Чужой токен — без эффекта."
  @spec release(Ecto.Repo.t(), String.t(), String.t(), lease()) :: :ok

  def release(repo, subscriber, topic, <<_::128>> = lease)
      when is_atom(repo) and is_binary(subscriber) and is_binary(topic) do
    _ = Ecto.Adapters.SQL.query!(repo, @release_sql, [subscriber, topic, lease])
    :ok
  end

  # ===== смещения =====

  @doc "Следующие смещения партиций топика подписчика; партиции без строки в map нет."
  @spec offsets(Ecto.Repo.t(), String.t(), String.t()) :: %{non_neg_integer() => non_neg_integer()}

  def offsets(repo, subscriber, topic) when is_atom(repo) and is_binary(subscriber) and is_binary(topic) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, @offsets_sql, [subscriber, topic])
    Map.new(rows, fn [partition, next_offset] -> {partition, next_offset} end)
  end

  @doc """
  Записать следующее смещение партиции под арендой `lease`.

  `{:error, %Error{code: :kafka_lease_lost}}` — аренда истекла или перешла к другому токену,
  смещение не записано.
  """
  @spec commit(Ecto.Repo.t(), String.t(), String.t(), lease(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, Error.t()}

  def commit(repo, subscriber, topic, <<_::128>> = lease, partition, next_offset)
      when is_atom(repo) and is_binary(subscriber) and is_binary(topic) and is_integer(partition) and
             partition >= 0 and is_integer(next_offset) and next_offset >= 0 do
    case Ecto.Adapters.SQL.query!(repo, @commit_sql, [subscriber, topic, partition, next_offset, lease]) do
      %{num_rows: 1} ->
        :ok

      %{num_rows: 0} ->
        {:error,
         Error.app(
           code: :kafka_lease_lost,
           ns: :mq,
           message: "Аренда топика Kafka потеряна: смещение не записано",
           detail: %{topic: topic, partition: partition}
         )}
    end
  end
end
