defmodule Core.Outbox.Repo.Pg do
  @moduledoc """
  PostgreSQL-реализация `Core.Outbox.Repo`.
  """

  @behaviour Core.Outbox.Repo

  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Exc
  alias Core.Helper.AfterCommit
  alias Core.Outbox
  alias Core.Outbox.Poller
  alias Core.Outbox.Record
  alias Core.Outbox.Repo.Pg.Schema
  alias Core.Outbox.Repo.Pg.Stats

  require Logger

  @persist_chunk_size 500

  @doc "Добавить записи outbox; после commit — wake poller."
  @spec append([Record.t()], Context.t(), keyword()) :: :ok

  @impl true
  def append(records, context, opts \\ [])

  def append([], %Context{}, opts) when is_list(opts), do: :ok

  def append(records, %Context{}, opts) when is_list(records) and is_list(opts) do
    persist_insert_all!(records, opts)
    AfterCommit.register(fn -> wake_pollers(records) end)
    :ok
  end

  @doc "Зарезервировать пачку записей (`:new` / просроченный `:in_work`)."
  @spec fetch_and_reserve(Outbox.BatchSize.t(), Outbox.LockDuration.t(), Context.t()) ::
          [Record.t()]

  @impl true
  def fetch_and_reserve(
        %Outbox.BatchSize{} = batch_size,
        %Outbox.LockDuration{} = lock_duration,
        %Context{} = context
      ) do
    fetch_and_reserve(batch_size, lock_duration, :all, context)
  end

  @doc "Зарезервировать пачку с фильтром топиков."
  @spec fetch_and_reserve(
          Outbox.BatchSize.t(),
          Outbox.LockDuration.t(),
          Outbox.topics_filter(),
          Context.t()
        ) :: [Record.t()]

  @impl true
  def fetch_and_reserve(
        %Outbox.BatchSize{} = batch_size,
        %Outbox.LockDuration{} = lock_duration,
        topics,
        %Context{}
      ) do
    now_utc = utc_now()
    locked_until_utc = DateTime.add(now_utc, Outbox.LockDuration.value(lock_duration), :second)

    with {:ok, updated_at} <- Outbox.UpdatedAt.new(now_utc),
         {:ok, locked_until} <- Outbox.LockedUntil.new(locked_until_utc),
         lease = %{
           locked_until: locked_until,
           lease_id: Outbox.LeaseID.new(),
           updated_at: updated_at
         },
         {:ok, records} <- reserve_batch(batch_size, now_utc, topics, lease) do
      records
    else
      {:error, %Error{} = error} -> raise Exc, error
    end
  end

  @doc """
  Сохранить результаты доставки (published / retry / failed).

  Запись идёт `UPDATE`-ом под токеном аренды: строка, перехваченная другим поллером
  после истечения аренды, и строка, удалённая `Cleaner`, не обновляются и не
  воскрешаются — расхождение уходит в лог.
  """
  @spec save_results([Record.t()], Context.t()) :: :ok

  @impl true
  def save_results([], %Context{}), do: :ok

  def save_results(records, %Context{}) when is_list(records) do
    {:ok, :ok} =
      Config.dao().transact(fn ->
        records
        |> Enum.group_by(&result_group/1)
        |> Enum.each(fn {{lease, set}, group} -> write_result_group(lease, set, group) end)

        {:ok, :ok}
      end)

    :ok
  end

  @doc "Снять аренду и вернуть записи в очередь (`:new`) под проверкой токена."
  @spec release([Record.t()], Context.t()) :: :ok

  @impl true
  def release([], %Context{}), do: :ok

  def release(records, %Context{}) when is_list(records) do
    updated_at = utc_now()

    records
    |> Enum.group_by(&dump_lease/1, &dump_id/1)
    |> Enum.each(fn {lease, ids} ->
      {_count, _} =
        from(r in Schema, where: r.id in ^ids)
        |> fence(lease)
        |> Config.dao().update_all(
          set: [status: :new, locked_until: nil, lease_id: nil, updated_at: updated_at]
        )
    end)

    :ok
  end

  @doc "Удалить published-записи старше `before`; вернуть число удалённых."
  @spec delete_published_before(Outbox.PublishedAt.t(), Context.t()) :: non_neg_integer()

  @impl true
  def delete_published_before(%Outbox.PublishedAt{} = before, %Context{}) do
    before_utc = Config.codec().dump(before)

    {count, _} =
      from(r in Schema,
        where: r.status == :published and r.published_at < ^before_utc
      )
      |> Config.dao().delete_all()

    count
  end

  @doc """
  Вернуть `:failed`-записи в очередь.

  Порядок доставки для возвращённых записей не восстанавливается: они встают в очередь
  по своему исходному `created_at`, а всё, что было опубликовано после них, уже ушло.
  """
  @spec requeue_failed(:all | [Outbox.ID.t()], Context.t()) :: non_neg_integer()

  @impl true
  def requeue_failed(target, %Context{}) when target == :all or is_list(target) do
    {count, _} =
      from(r in Schema, where: r.status == :failed)
      |> filter_ids(target)
      |> Config.dao().update_all(
        set: [status: :new, attempts: 0, locked_until: nil, updated_at: utc_now()]
      )

    count
  end

  @doc "Число записей по каждому статусу."
  @spec counts_by_status() :: %{Outbox.Status.t() => non_neg_integer()}

  @impl true
  defdelegate counts_by_status(), to: Stats

  @doc "Возраст самой старой записи статуса в секундах."
  @spec oldest_age_seconds(Outbox.Status.t()) :: non_neg_integer() | nil

  @impl true
  defdelegate oldest_age_seconds(status), to: Stats

  @doc "Число `:in_work` с истёкшим `locked_until`."
  @spec expired_lock_count() :: non_neg_integer()

  @impl true
  defdelegate expired_lock_count(), to: Stats

  # ---

  defp filter_ids(query, :all), do: query

  defp filter_ids(query, ids) when is_list(ids) do
    codec = Config.codec()
    dumped = Enum.map(ids, &codec.dump/1)

    from(r in query, where: r.id in ^dumped)
  end

  defp reserve_batch(batch_size, now_utc, topics, lease) do
    Config.dao().transact(fn ->
      rows =
        from(r in Schema,
          where:
            r.status == :new or
              (r.status == :in_work and r.locked_until <= ^now_utc),
          order_by: [asc: r.created_at, asc: r.id],
          limit: ^Outbox.BatchSize.value(batch_size),
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> apply_topics_filter(topics)
        |> Config.dao().all()

      {records, poisoned} = reserve_rows(rows, lease)
      fail_poisoned(poisoned, lease.updated_at)
      persist_all!(records)
      {:ok, records}
    end)
  end

  defp apply_topics_filter(query, :all), do: query

  defp apply_topics_filter(query, {:only, []}), do: from(r in query, where: false)

  defp apply_topics_filter(query, {:only, topics}) when is_list(topics) do
    from(r in query, where: r.topic in ^topics)
  end

  defp apply_topics_filter(query, {:except, []}), do: query

  defp apply_topics_filter(query, {:except, topics}) when is_list(topics) do
    from(r in query, where: r.topic not in ^topics)
  end

  defp wake_pollers(records) do
    topics = MapSet.new(records, fn record -> Outbox.Topic.value(record.topic) end)

    Enum.each(poller_targets(), fn {name, filter} ->
      if Outbox.topics_match?(topics, filter), do: Poller.wake(name)
    end)
  end

  defp poller_targets do
    cfg = Application.get_env(:core, Outbox, [])

    case Keyword.get(cfg, :pollers) do
      [_ | _] = list ->
        Enum.map(list, fn poller ->
          {Keyword.fetch!(poller, :name), Keyword.fetch!(poller, :topics)}
        end)

      _ ->
        [{Keyword.get(cfg, :poller_name), :all}]
    end
  end

  defp reserve_rows(rows, lease) do
    {records, poisoned} =
      Enum.reduce(rows, {[], []}, fn row, {records, poisoned} ->
        case reserve_row(row, lease) do
          {:ok, record} -> {[record | records], poisoned}
          {:error, %Error{} = error} -> {records, [{row, error} | poisoned]}
        end
      end)

    {Enum.reverse(records), Enum.reverse(poisoned)}
  end

  defp reserve_row(row, lease) do
    with {:ok, entity} <- Schema.to_entity(row) do
      Record.reserve(entity, lease.locked_until, lease.lease_id, lease.updated_at)
    end
  end

  # Строка, которую не разобрать кодеком, при halt на первой ошибке откатывала бы
  # резервацию всей пачки, а из-за `order_by: created_at` попадала бы в каждую
  # следующую — очередь встала бы навсегда. Помечаем её `:failed` мимо кодека
  # (запись уже не декодируется) и продолжаем с остальными.
  defp fail_poisoned([], _updated_at), do: :ok

  defp fail_poisoned(poisoned, updated_at) do
    updated_at_utc = Config.codec().dump(updated_at)

    Enum.each(poisoned, fn {row, error} ->
      log_poisoned(row, error)
      mark_row_failed(row, error, updated_at_utc)
    end)
  end

  defp log_poisoned(row, error) do
    Logger.error(
      "Outbox: строка не разобрана, помечена failed: id=#{row.id} " <>
        "topic=#{inspect(row.topic)} name=#{inspect(row.name)} " <>
        "ошибка=#{Error.format_chain(error)}"
    )
  end

  defp mark_row_failed(row, error, updated_at_utc) do
    entry = Jason.encode!([%{attempt: row.attempts + 1, message: Error.format_chain(error)}])

    {_count, _} =
      from(r in Schema,
        where: r.id == ^row.id,
        update: [
          set: [
            status: ^:failed,
            locked_until: nil,
            updated_at: ^updated_at_utc,
            errors: fragment("? || ?::jsonb", r.errors, type(^entry, :string))
          ],
          inc: [attempts: 1]
        ]
      )
      |> Config.dao().update_all([])

    :ok
  end

  # Записи с одинаковым набором устанавливаемых значений и одной арендой пишутся
  # одним UPDATE: при fail-stop это published-префикс, released-хвост и одна
  # проваленная запись — три запроса вместо построчных.
  defp result_group(%Record{} = record) do
    row = Schema.to_model!(record)

    set = [
      status: row.status,
      attempts: row.attempts,
      errors: row.errors,
      locked_until: nil,
      lease_id: nil,
      published_at: row.published_at,
      updated_at: row.updated_at
    ]

    {row.lease_id, set}
  end

  defp write_result_group(lease, set, records) do
    ids = Enum.map(records, &dump_id/1)

    {count, _} =
      from(r in Schema, where: r.id in ^ids)
      |> fence(lease)
      |> Config.dao().update_all(set: set)

    log_lost_lease(count, records)
  end

  defp fence(query, nil), do: from(r in query, where: is_nil(r.lease_id))

  defp fence(query, lease), do: from(r in query, where: r.lease_id == ^lease)

  defp dump_lease(%Record{lease_id: nil}), do: nil

  defp dump_lease(%Record{lease_id: lease_id}), do: Config.codec().dump(lease_id)

  defp dump_id(%Record{id: id}), do: Config.codec().dump(id)

  defp log_lost_lease(count, records) when count == length(records), do: :ok

  defp log_lost_lease(count, records) do
    Logger.warning(
      "Outbox: результат доставки не записан, аренда перехвачена или запись удалена: " <>
        "ожидалось=#{length(records)} записано=#{count} " <>
        "ids=#{Enum.map_join(records, ",", &Outbox.ID.format(&1.id, :hex))}"
    )
  end

  defp persist_all!([]), do: :ok

  defp persist_all!(records) when is_list(records) do
    records
    |> Enum.chunk_every(@persist_chunk_size)
    |> Enum.each(&persist_upsert_chunk!/1)

    :ok
  end

  defp persist_insert_all!(records, opts) do
    records
    |> Enum.chunk_every(@persist_chunk_size)
    |> Enum.each(fn chunk ->
      rows = Enum.map(chunk, &Schema.to_model!/1)
      {_count, _} = Config.dao().insert_all(Schema, rows, opts)
    end)
  end

  defp persist_upsert_chunk!(chunk) do
    rows = Enum.map(chunk, &Schema.to_model!/1)

    {_count, _} =
      Config.dao().insert_all(Schema, rows,
        on_conflict:
          {:replace,
           [
             :topic,
             :key,
             :name,
             :payload,
             :status,
             :attempts,
             :locked_until,
             :lease_id,
             :errors,
             :updated_at,
             :published_at
           ]},
        conflict_target: [:id]
      )

    :ok
  end

  defp utc_now, do: DateTime.utc_now()
end
