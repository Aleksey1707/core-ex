defmodule Core.Outbox.Repo.Pg.Stats do
  @moduledoc """
  SQL-агрегаты таблицы outbox для polling-метрик PromEx.
  """

  import Ecto.Query
  import Core.Guard

  alias Core.Config
  alias Core.Outbox
  alias Core.Outbox.Repo.Pg.Schema

  @doc "Число записей по каждому статусу (отсутствующие статусы → 0)."
  @spec counts_by_status() :: %{Outbox.Status.t() => non_neg_integer()}

  def counts_by_status do
    rows =
      from(r in Schema, group_by: r.status, select: {r.status, count(r.id)})
      |> Config.dao().all()
      |> Map.new()

    Map.new(Outbox.Status.values(), fn status -> {status, Map.get(rows, status, 0)} end)
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
end
