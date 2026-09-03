defmodule Core.Repo.Pg.Children do
  @moduledoc """
  Синхронизация дочерних строк агрегата: пишется только то, что изменилось.

  Обычные функции с конфигом `@pg` (`Core.Repo.Pg`) первым аргументом; спеки дочерних таблиц
  строит `Core.Repo.Pg.Es` на этапе компиляции.

  | Путь | Запросов на дочернюю таблицу |
  |---|---|
  | `insert/4` — родитель только что создан | `insert_all` (без `on_conflict`) |
  | `sync/5` с эталоном | 0..2: `delete_all` исчезнувших ключей + `insert_all` новых и изменившихся |
  | `sync/5` без эталона | 2: `delete_all` всего, чего нет в наборе + `insert_all` набора |

  Обе стороны diff — результат **одной и той же** `to_models/1` (эталон-агрегат vs текущий), не
  строка из БД: jsonb-колонки после round-trip через Postgres получают строковые ключи, и diff был
  бы вечным.

  Контракты дочерней схемы:

  - `to_models/1` возвращает **все** колонки таблицы — пропущенную обнулит `on_conflict: {:replace, ...}`;
  - ключ (`key`) уникален внутри набора: дубль — `ArgumentError` (при upsert он стал бы тихим затиранием).

  Ошибки БД (`insert_all` идёт мимо changeset) мапятся в доменные по имени constraint'а, если у спека
  задан `constraint_errors`: запись оборачивается в SAVEPOINT, чтобы внешняя транзакция не оказалась
  в aborted-состоянии и доменная ошибка вела себя так же, как ошибка записи из `Repo.Pg`.
  """

  import Ecto.Query, only: [dynamic: 2, from: 2]

  alias Core.Error
  alias Core.Helper
  alias Core.Repo

  @chunk_size 500

  @typedoc "Спека дочерней таблицы (строится `Repo.Pg.Es` на этапе компиляции)."
  @type spec :: %{
          schema: module(),
          fk: atom(),
          key: [atom(), ...],
          conflict_target: [atom(), ...],
          replace: [atom()],
          constraint_errors: %{String.t() => atom()}
        }

  @typedoc "План записи: новые строки, изменившиеся строки, ключи исчезнувших строк."
  @type plan :: %{insert: [map()], update: [map()], delete: [map()]}

  @doc """
  Записать дочерние строки только что вставленного агрегата.

  Родителя в БД до этого не было, поэтому ни `delete_all`, ни `on_conflict` не нужны.
  """
  @spec insert(map(), [spec()], struct(), Repo.opts()) :: :ok | {:error, Error.t()}

  def insert(pg, specs, entity, opts) do
    each_spec(specs, &insert_rows(pg, &1, entity, opts))
  end

  @doc """
  Синхронизировать дочерние строки агрегата с БД.

  `baseline` — эталон агрегата (`Repo.Pg.baseline/3`) или `nil`. С эталоном пишется только diff;
  без него — `delete_all` всего, чего нет в текущем наборе, плюс upsert набора.
  """
  @spec sync(map(), [spec()], struct(), struct() | nil, Repo.opts()) :: :ok | {:error, Error.t()}

  def sync(pg, specs, entity, baseline, opts) do
    each_spec(specs, &sync_rows(pg, &1, entity, baseline, opts))
  end

  @doc """
  План записи: строки без ключа в эталоне — в `insert`, с отличиями — в `update`,
  ключи, которых нет в текущем наборе, — в `delete`.
  """
  @spec plan(spec(), [map()], [map()]) :: plan()

  def plan(spec, baseline_rows, rows) do
    was = index(spec, baseline_rows)
    now = index(spec, rows)

    %{
      insert: Enum.reject(rows, &Map.has_key?(was, key(spec, &1))),
      update: Enum.filter(rows, &changed?(spec, was, &1)),
      delete:
        baseline_rows
        |> Enum.map(&key(spec, &1))
        |> Enum.reject(&Map.has_key?(now, &1))
    }
  end

  @doc false
  @spec chunk_size() :: pos_integer()

  def chunk_size, do: @chunk_size

  # ---

  defp each_spec(specs, fun) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      case fun.(spec) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp insert_rows(pg, spec, entity, opts) do
    guarded(pg, spec, fn -> insert_all(pg, spec.schema, rows(spec, entity), opts) end)
  end

  defp sync_rows(pg, spec, entity, nil, opts) do
    rows = rows(spec, entity)

    guarded(pg, spec, fn ->
      with :ok <- prune(pg, spec, entity, rows, opts), do: upsert(pg, spec, rows, opts)
    end)
  end

  defp sync_rows(pg, spec, entity, baseline, opts) do
    write(pg, spec, entity, plan(spec, rows(spec, baseline), rows(spec, entity)), opts)
  end

  defp write(_pg, _spec, _entity, %{insert: [], update: [], delete: []}, _opts), do: :ok

  defp write(pg, spec, entity, plan, opts) do
    guarded(pg, spec, fn ->
      with :ok <- delete_keys(pg, spec, entity, plan.delete, opts),
           do: upsert(pg, spec, plan.insert ++ plan.update, opts)
    end)
  end

  defp guarded(_pg, %{constraint_errors: mapping}, fun) when map_size(mapping) == 0, do: fun.()

  defp guarded(pg, spec, fun) do
    Helper.Savepoint.run(pg.dao, fn -> rescue_constraint(pg, spec, fun) end)
  end

  defp rescue_constraint(pg, spec, fun) do
    fun.()
  rescue
    e in Postgrex.Error ->
      case Map.fetch(spec.constraint_errors, constraint_name(e)) do
        {:ok, code} -> {:error, pg.errors.domain(pg.module, code, e)}
        :error -> reraise e, __STACKTRACE__
      end
  end

  defp constraint_name(%Postgrex.Error{postgres: %{constraint: name}}) when is_binary(name),
    do: name

  defp constraint_name(%Postgrex.Error{}), do: nil

  defp delete_keys(_pg, _spec, _entity, [], _opts), do: :ok

  defp delete_keys(pg, spec, entity, keys, opts) do
    fk_value = entity_id(pg, entity)
    filter = key_filter(spec, keys)

    delete_all(pg, spec, dynamic([c], field(c, ^spec.fk) == ^fk_value and ^filter), opts)
  end

  defp prune(pg, spec, entity, [], opts) do
    fk_value = entity_id(pg, entity)

    delete_all(pg, spec, dynamic([c], field(c, ^spec.fk) == ^fk_value), opts)
  end

  defp prune(pg, spec, entity, rows, opts) do
    fk_value = entity_id(pg, entity)
    filter = key_filter(spec, Enum.map(rows, &key(spec, &1)))

    delete_all(pg, spec, dynamic([c], field(c, ^spec.fk) == ^fk_value and not (^filter)), opts)
  end

  defp delete_all(pg, spec, where, opts) do
    {_deleted, _} = pg.dao.delete_all(from(c in spec.schema, where: ^where), opts)

    :ok
  end

  defp key_filter(%{key: [column]}, keys) do
    values = Enum.map(keys, &Map.fetch!(&1, column))

    dynamic([c], field(c, ^column) in ^values)
  end

  defp key_filter(%{key: columns}, keys) do
    Enum.reduce(keys, dynamic([_c], false), fn key, acc ->
      dynamic([c], ^acc or ^row_filter(columns, key))
    end)
  end

  defp row_filter(columns, key) do
    Enum.reduce(columns, dynamic([_c], true), fn column, acc ->
      value = Map.fetch!(key, column)

      dynamic([c], ^acc and field(c, ^column) == ^value)
    end)
  end

  defp upsert(_pg, _spec, [], _opts), do: :ok

  defp upsert(pg, spec, rows, opts) do
    upsert_opts = [on_conflict: on_conflict(spec), conflict_target: spec.conflict_target] ++ opts

    insert_all(pg, spec.schema, rows, upsert_opts)
  end

  defp on_conflict(%{replace: []}), do: :nothing
  defp on_conflict(%{replace: replace}), do: {:replace, replace}

  defp insert_all(_pg, _schema, [], _opts), do: :ok

  defp insert_all(pg, schema, rows, opts) do
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(fn chunk -> {_count, _} = pg.dao.insert_all(schema, chunk, opts) end)

    :ok
  end

  defp index(spec, rows) do
    indexed = Map.new(rows, &{key(spec, &1), &1})

    if map_size(indexed) != length(rows), do: raise_duplicate_key(spec)

    indexed
  end

  defp raise_duplicate_key(spec) do
    raise ArgumentError,
          "#{inspect(spec.schema)}.to_models/1: дублирующиеся ключи #{inspect(spec.key)}"
  end

  defp changed?(spec, was, row) do
    case Map.fetch(was, key(spec, row)) do
      {:ok, before} -> before != row
      :error -> false
    end
  end

  defp key(spec, row), do: Map.take(row, spec.key)

  defp rows(spec, entity), do: spec.schema.to_models(entity)

  defp entity_id(pg, entity), do: pg.to_id.(entity.id)
end
