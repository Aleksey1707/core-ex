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

  Жизненный цикл кэша — `init/1` → `clear/1` → `delete/1`; каждая из трёх возвращает контекст,
  и дальше работать нужно именно с ним: контекст неизменяем, а старая копия держит ссылку на
  уже удалённую таблицу.

  Таблица принадлежит процессу, который вызвал `init/1`. Приватная ETS доступна только владельцу:
  в чужом процессе `put/2` — no-op, `find/3` — `nil`, `delete/1` и `clear/1` чужую живую таблицу
  не трогают. Кэш — оптимизация write-пути: без эталона `Children.sync` идёт широким diff, и
  корректность записи от этого не страдает.

  Эталон в ETS расходится с БД только при прямом `Repo.Pg.put_baseline/3` внутри транзакции:
  штатная запись регистрирует эталон после commit (`Helper.AfterCommit.register/1`).
  """

  alias Core.Context

  @context_key :shadow_copy

  # ===== таблица =====

  @doc "Включить снэпшот-кэш для контекста (создаёт приватную ETS-таблицу)."
  @spec init(Context.t()) :: Context.t()

  def init(context) do
    Context.put(context, @context_key, :ets.new(:shadow_copy, [:set, :private]))
  end

  @doc """
  Удалить ETS-таблицу shadow copy и снять ключ с контекста.

  No-op, если кэш не включён или таблица уже удалена. Чужую живую таблицу не удаляет и ключ
  с контекста не снимает.
  """
  @spec delete(Context.t()) :: Context.t()

  def delete(context) do
    case own_table(context) do
      nil ->
        forget_dead(context)

      tid ->
        :ets.delete(tid)
        Context.delete(context, @context_key)
    end
  end

  @doc """
  Забыть все эталоны, оставив кэш включённым.

  Возвращает тот же контекст; если таблица уже удалена — контекст без мёртвого ключа.
  No-op, если кэш не включён. Чужую живую таблицу не чистит.
  """
  @spec clear(Context.t()) :: Context.t()

  def clear(context) do
    case own_table(context) do
      nil ->
        forget_dead(context)

      tid ->
        :ets.delete_all_objects(tid)
        context
    end
  end

  # ---

  @spec forget_dead(Context.t()) :: Context.t()

  defp forget_dead(context) do
    case Context.find(context, @context_key) do
      nil -> context
      tid -> drop_dead_key(tid, context)
    end
  end

  @spec drop_dead_key(:ets.tid(), Context.t()) :: Context.t()

  defp drop_dead_key(tid, context) do
    if alive?(tid), do: context, else: Context.delete(context, @context_key)
  end

  defp alive?(table), do: :ets.info(table) != :undefined

  # ===== запись =====

  @doc """
  Зафиксировать эталон сущности: состояние на момент последнего чтения или успешной записи.

  Перезаписывает предыдущий эталон: и повторное чтение, и запись обязаны его обновить — иначе
  следующая запись считала бы diff дочерних строк от устаревшей копии.

  No-op, если кэш не включён, таблица уже удалена (`delete/1` на другой копии контекста) или
  принадлежит другому процессу.
  """
  @spec put(Context.t(), struct()) :: struct()

  def put(context, %mod{id: id} = entity) do
    case own_table(context) do
      nil -> :ok
      table -> :ets.insert(table, {{mod, id}, entity})
    end

    entity
  end

  # ===== чтение =====

  @doc """
  Вернуть ранее зафиксированный эталон сущности `module` по id.

  `nil`, если кэш не включён, таблица уже удалена, принадлежит другому процессу или записи нет.
  """
  @spec find(Context.t(), module(), term()) :: struct() | nil

  def find(context, module, id) when is_atom(module) do
    case own_table(context) do
      nil -> nil
      table -> do_lookup(table, {module, id})
    end
  end

  # ---

  defp do_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, entity}] -> entity
      [] -> nil
    end
  end

  # ===== общее =====

  defp own_table(context) do
    tid = Context.find(context, @context_key)

    with true <- is_reference(tid),
         true <- :ets.info(tid, :owner) == self() do
      tid
    else
      _ -> nil
    end
  end
end
