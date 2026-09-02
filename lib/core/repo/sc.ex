defmodule Core.Repo.Sc do
  @moduledoc """
  Снэпшот-кэш ("shadow copy").

  Хранит "чистую" версию сущности на момент её чтения из БД в рамках
  одного запроса/юзкейса — чтобы перед записью можно было определить,
  реально ли она изменилась, и избежать лишнего похода в БД.

  Живёт в `Core.Context` как ссылка на приватную ETS-таблицу.

  Ключ — пара `{модуль сущности, id}`: разные агрегаты могут иметь один идентификатор
  (например `User` и `AuthSettings`), и общий ключ по `id` подменял бы их эталоны.

  Эталон кладут только write-репозитории (`shadow_copy?: true`), и их `query:` обязан читать
  агрегат целиком — с полными preload дочерних ассоциаций и без фильтрации детей. Узкое чтение
  затёрло бы полный эталон, и diff дочерних строк пропустил бы удаления.
  """

  alias Core.Context

  @context_key :shadow_copy

  @doc "Включить снэпшот-кэш для контекста (создаёт приватную ETS-таблицу)."
  @spec init(Context.t()) :: Context.t()

  def init(context) do
    Context.put(context, @context_key, :ets.new(:shadow_copy, [:set, :private]))
  end

  @doc """
  Удалить ETS-таблицу shadow copy.

  No-op, если кэш не включён или таблица уже удалена.
  """
  @spec delete(Context.t()) :: :ok

  def delete(context) do
    case Context.find(context, @context_key) do
      nil -> :ok
      tid -> do_delete(tid)
    end
  end

  @doc """
  Забыть все эталоны, оставив кэш включённым.

  No-op, если кэш не включён или таблица уже удалена.
  """
  @spec clear(Context.t()) :: :ok

  def clear(context) do
    case Context.find(context, @context_key) do
      nil -> :ok
      tid -> do_clear(tid)
    end
  end

  # ---

  @spec do_delete(:ets.tid()) :: :ok

  defp do_delete(tid) do
    if :ets.info(tid) != :undefined, do: :ets.delete(tid)
    :ok
  end

  @spec do_clear(:ets.tid()) :: :ok

  defp do_clear(tid) do
    if :ets.info(tid) != :undefined, do: :ets.delete_all_objects(tid)
    :ok
  end

  @doc """
  Зафиксировать эталон сущности: состояние на момент последнего чтения или успешной записи.

  Перезаписывает предыдущий эталон: и повторное чтение, и запись обязаны его обновить — иначе
  следующая запись считала бы diff дочерних строк от устаревшей копии.

  No-op, если кэш не включён.

  После отката транзакции эталон в ETS расходится с БД — такой контекст непригоден для
  последующих записей.
  """
  @spec put(Context.t(), struct()) :: struct()

  def put(context, %mod{id: id} = entity) do
    case Context.find(context, @context_key) do
      nil -> :ok
      table -> :ets.insert(table, {{mod, id}, entity})
    end

    entity
  end

  @doc """
  Вернуть ранее зафиксированный эталон сущности `module` по id.

  `nil`, если кэш не включён или записи нет.
  """
  @spec fetch(Context.t(), module(), term()) :: struct() | nil

  def fetch(context, module, id) when is_atom(module) do
    case Context.find(context, @context_key) do
      nil -> nil
      table -> lookup(table, {module, id})
    end
  end

  # ---

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, entity}] -> entity
      [] -> nil
    end
  end
end
