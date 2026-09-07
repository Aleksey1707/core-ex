defmodule Core.Outbox.Repo.Pg.Stats do
  @moduledoc """
  SQL-агрегаты таблицы outbox для polling-метрик PromEx.
  """

  import Ecto.Query
  import Core.Guard

  alias Core.Config
  alias Core.Outbox
  alias Core.Outbox.Repo.Pg.Schema

  @queue_statuses ~w(new in_work failed)a

  @doc """
  Число невыполненных записей по статусам `:new` / `:in_work` / `:failed`.

  `:published` не считается намеренно: это архив, ждущий TTL, и он единственный растёт
  неограниченно. `GROUP BY status` по всей таблице — seq scan на каждый опрос метрик
  (замер на 400k строк: 28–40 мс), тогда как счёт по трём частичным индексам —
  Index Only Scan (0,14 мс на здоровой очереди, 23 мс на забитой). Про запас
  опубликованных говорят метрики `Cleaner` и размер таблицы.
  """
  @spec queue_counts() :: %{Outbox.Status.t() => non_neg_integer()}

  def queue_counts do
    Map.new(@queue_statuses, fn status -> {status, count_status(status)} end)
  end

  @doc "Возраст самой старой записи статуса в секундах; `nil` если записей нет."
  @spec oldest_age_seconds(Outbox.Status.t()) :: non_neg_integer() | nil

  def oldest_age_seconds(status) when is_enum(status, Outbox.Status) do
    case from(r in Schema,
           where: r.status == ^status,
           select: min(r.created_at)
         )
         |> Config.dao().one() do
      nil ->
        nil

      %DateTime{} = created_at ->
        DateTime.diff(DateTime.utc_now(), created_at, :second)
    end
  end

  @doc "Число `:in_work` с истёкшим `locked_until`."
  @spec expired_lock_count() :: non_neg_integer()

  def expired_lock_count do
    now = DateTime.utc_now(:second)

    from(r in Schema,
      where: r.status == :in_work and r.locked_until <= ^now,
      select: count(r.id)
    )
    |> Config.dao().one()
  end

  # ---

  defp count_status(status) do
    from(r in Schema, where: r.status == ^status, select: count(r.id))
    |> Config.dao().one()
  end
end
