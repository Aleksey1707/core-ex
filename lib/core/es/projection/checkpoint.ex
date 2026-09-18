defmodule Core.Es.Projection.Checkpoint do
  @moduledoc """
  Чекпоинт проекции — строка `es_checkpoints` (`Core.Es.Migration`) — и блокировка пачки.

  Позиция строки — глобальная позиция последнего обработанного события
  (`t:Core.Es.Store.position/0`), `nil` — начало истории. Цель — позиция, до которой идёт
  пересборка, `nil` — цели нет. Запросы идут в транзакции пачки на `repo:` проекции
  (`Core.Es.Projection.run_once/2`); `find/1` зовёт и ожидание проекции
  (`await/3` модуля проекции) вне транзакции, `list/1` — метрики `Core.Es.PromEx`.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Es.Projection

  require Error

  # Блокировка парой ключей `(int4, int4)` не пересекается с блокировками одним bigint-ключом
  # (`Core.Helper.Lock`); первый ключ отделяет проекции от прочих пар. Имена с одним `hashtext`
  # делят блокировку: их пачки не идут одновременно, корректность держит CAS.
  @lock_sql "SELECT pg_try_advisory_xact_lock(hashtext('core.es.projection'), hashtext($1))"
  @find_sql "SELECT xid, number, version, target_xid, target_number FROM es_checkpoints WHERE name = $1"
  @list_sql "SELECT name, xid, number, version, target_xid, target_number FROM es_checkpoints"
  @insert_sql "INSERT INTO es_checkpoints (name, version, target_xid, target_number) " <>
                "VALUES ($1, $2, $3, $4) ON CONFLICT (name) DO NOTHING"
  @restart_sql "UPDATE es_checkpoints " <>
                 "SET xid = NULL, number = NULL, version = $2, target_xid = $3, target_number = $4 " <>
                 "WHERE name = $1 AND version = $5 " <>
                 "AND xid IS NOT DISTINCT FROM $6 AND number IS NOT DISTINCT FROM $7"
  @move_sql "UPDATE es_checkpoints SET xid = $2, number = $3 " <>
              "WHERE name = $1 AND version = $4 " <>
              "AND xid IS NOT DISTINCT FROM $5 AND number IS NOT DISTINCT FROM $6"
  @delete_sql "DELETE FROM es_checkpoints WHERE name = $1"
  @restore_sql "INSERT INTO es_checkpoints " <>
                 "(name, xid, number, version, target_xid, target_number) " <>
                 "VALUES ($1, $2, $3, $4, $5, $6) " <>
                 "ON CONFLICT (name) DO UPDATE SET xid = EXCLUDED.xid, number = EXCLUDED.number, " <>
                 "version = EXCLUDED.version, target_xid = EXCLUDED.target_xid, " <>
                 "target_number = EXCLUDED.target_number"

  @typedoc """
  Строка чекпоинта: позиция (`nil` — начало истории), версия проекции строки и цель пересборки
  (`nil` — цели нет).
  """
  @type t :: %{
          position: Es.Store.position() | nil,
          version: pos_integer(),
          target: Es.Store.position() | nil
        }

  # ===== блокировка =====

  @doc "Взять блокировку пачки проекции до конца транзакции; `false` — её держит другая пачка."
  @spec try_lock(Projection.t()) :: boolean()

  def try_lock(%{dao: dao, name: name}) do
    %{rows: [[locked]]} = Ecto.Adapters.SQL.query!(dao, @lock_sql, [name])
    locked
  end

  # ===== чтение =====

  @doc "Строка чекпоинта проекции; `nil` — строки нет."
  @spec find(Projection.t()) :: t() | nil

  def find(%{dao: dao, name: name}) do
    case Ecto.Adapters.SQL.query!(dao, @find_sql, [name]) do
      %{rows: []} -> nil
      %{rows: [columns]} -> row(columns)
    end
  end

  @doc "Строки чекпоинтов всех проекций с именами."
  @spec list(Ecto.Repo.t()) :: [{String.t(), t()}]

  def list(dao) when is_atom(dao) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(dao, @list_sql, [])
    Enum.map(rows, fn [name | columns] -> {name, row(columns)} end)
  end

  # ---

  defp row([xid, number, version, target_xid, target_number]) do
    %{
      position: position(xid, number),
      version: version,
      target: position(target_xid, target_number)
    }
  end

  defp position(nil, nil), do: nil
  defp position(xid, number), do: {xid, number}

  # ===== состояние =====

  @doc """
  Read-модель проекции неполна по строке `checkpoint`: строки нет, её версия ниже `version:`
  объявления или позиция ниже цели пересборки.
  """
  @spec rebuilding?(t() | nil, Projection.t()) :: boolean()

  def rebuilding?(nil, _declaration), do: true
  def rebuilding?(%{version: version}, %{version: current}) when version < current, do: true

  def rebuilding?(%{position: position, target: target}, _declaration),
    do: below?(position, target)

  @doc "Версия строки `checkpoint` выше `version:` объявления: пачки этого кода — `:outdated`."
  @spec outdated?(t() | nil, Projection.t()) :: boolean()

  def outdated?(nil, _declaration), do: false
  def outdated?(%{version: version}, %{version: current}), do: version > current

  # ---

  defp below?(_position, nil), do: false
  defp below?(nil, _target), do: true
  defp below?(position, target), do: position < target

  # ===== запись =====

  @doc """
  Записать строку в начале истории с версией проекции и целью `target` при условии, что строка
  равна прочитанной `checkpoint` (`nil` — строки не было); иначе — `:checkpoint_conflict`.
  """
  @spec start(Projection.t(), t() | nil, Es.Store.position() | nil) :: :ok | {:error, Error.t()}

  def start(%{name: name, version: version} = declaration, nil, target) do
    {target_xid, target_number} = columns(target)
    compare_and_set(declaration, @insert_sql, [name, version, target_xid, target_number])
  end

  def start(
        %{name: name, version: version} = declaration,
        %{position: from, version: from_version},
        target
      ) do
    {target_xid, target_number} = columns(target)
    {from_xid, from_number} = columns(from)
    params = [name, version, target_xid, target_number, from_version, from_xid, from_number]

    compare_and_set(declaration, @restart_sql, params)
  end

  @doc """
  Сдвинуть позицию строки на `to` при условии, что строка равна прочитанной `checkpoint`;
  иначе — `:checkpoint_conflict`.
  """
  @spec move(Projection.t(), t(), Es.Store.position()) :: :ok | {:error, Error.t()}

  def move(%{name: name} = declaration, %{position: from, version: version}, {xid, number}) do
    {from_xid, from_number} = columns(from)
    params = [name, xid, number, version, from_xid, from_number]

    compare_and_set(declaration, @move_sql, params)
  end

  @doc false
  @spec delete(Projection.t()) :: :ok

  def delete(%{dao: dao, name: name}) do
    Ecto.Adapters.SQL.query!(dao, @delete_sql, [name])
    :ok
  end

  @doc false
  @spec restore(Projection.t(), t() | nil) :: :ok

  def restore(declaration, nil), do: delete(declaration)

  def restore(%{dao: dao, name: name}, %{position: position, version: version, target: target}) do
    {xid, number} = columns(position)
    {target_xid, target_number} = columns(target)
    params = [name, xid, number, version, target_xid, target_number]

    Ecto.Adapters.SQL.query!(dao, @restore_sql, params)
    :ok
  end

  # ---

  defp compare_and_set(%{dao: dao} = declaration, sql, params) do
    case Ecto.Adapters.SQL.query!(dao, sql, params) do
      %{num_rows: 1} -> :ok
      %{num_rows: 0} -> {:error, conflict(declaration)}
    end
  end

  defp columns(nil), do: {nil, nil}
  defp columns({_xid, _number} = position), do: position

  defp conflict(declaration) do
    Error.app(
      code: :checkpoint_conflict,
      ns: :es,
      message: "Чекпоинт проекции изменён в обход блокировки пачки",
      detail: %{projection: declaration.name}
    )
  end
end
