defmodule Core.Helper.AfterCommit do
  @moduledoc """
  Хуки после успешного outermost DB-commit.

  `register/1` внутри транзакции копит callback; вне TX вызывает сразу.
  `wrap/1` — depth-счётчик вложенных `Repo.transact` / savepoint.

  Под тем же счётчиком живут значения внешней транзакции (`get_or_put_in_transaction/2`): они
  сбрасываются на её commit и rollback — так операция событий одна на транзакцию
  (`Core.Es.Operation`).
  """

  alias Core.Config

  require Logger

  @hooks_key {__MODULE__, :hooks}
  @depth_key {__MODULE__, :depth}
  @values_key {__MODULE__, :values}

  # ===== регистрация =====

  @doc """
  Регистрирует callback после commit.

  Вне транзакции вызывает `fun` сразу.
  """
  @spec register((-> any())) :: :ok

  def register(fun) when is_function(fun, 0) do
    if Config.dao().in_transaction?() do
      Process.put(@hooks_key, [fun | Process.get(@hooks_key, [])])
      :ok
    else
      _ = fun.()
      :ok
    end
  end

  # ===== значения транзакции =====

  @doc """
  Значение `key` на внешнюю транзакцию: `fun` вычисляется при первом вызове, следующие вызовы той
  же транзакции получают его же. Значение сбрасывается на commit и rollback внешней транзакции.

  Вне транзакции — `fun.()` на каждый вызов.
  """
  @spec get_or_put_in_transaction(term(), (-> value)) :: value when value: var

  def get_or_put_in_transaction(key, fun) when is_function(fun, 0) do
    case Process.get(@depth_key, 0) do
      0 -> fun.()
      _depth -> fetch_or_put(key, fun)
    end
  end

  # ---

  defp fetch_or_put(key, fun) do
    values = Process.get(@values_key, %{})

    case Map.fetch(values, key) do
      {:ok, value} ->
        value

      :error ->
        value = fun.()
        Process.put(@values_key, Map.put(values, key, value))
        value
    end
  end

  # ===== обёртка транзакции =====

  @doc """
  Оборачивает `Repo.transact`: хуки только после outermost `{:ok, _}`.
  """
  @spec wrap((-> result)) :: result when result: var

  def wrap(transact_fun) when is_function(transact_fun, 0) do
    depth = Process.get(@depth_key, 0)
    Process.put(@depth_key, depth + 1)
    if depth == 0, do: start_outermost()

    try do
      result = transact_fun.()

      # Depth сбрасывается до запуска хуков (и повторно в `after` — для пути с
      # исключением): хук вправе открыть свою транзакцию и должен видеть outermost.
      Process.put(@depth_key, depth)
      if depth == 0 and match?({:ok, _}, result), do: drain_hooks()
      result
    after
      Process.put(@depth_key, depth)

      if depth == 0 do
        Process.delete(@hooks_key)
        Process.delete(@values_key)
        Process.delete(@depth_key)
      end
    end
  end

  # ---

  # Хук after-commit, открывший свою транзакцию, начинает её с чистыми значениями: внешняя
  # транзакция к этому моменту уже закоммичена.
  defp start_outermost do
    Process.put(@hooks_key, [])
    Process.delete(@values_key)
  end

  # Очередь забирается из process dictionary целиком перед запуском: хук вправе открыть
  # свою транзакцию, а её `wrap` заведёт собственный список хуков поверх этого ключа.
  # Depth к этому моменту уже сброшен — иначе вложенный `wrap` не увидел бы outermost
  # уровень и зарегистрированные в нём хуки были бы стёрты вместе с ключом.
  defp drain_hooks do
    case Process.put(@hooks_key, []) do
      hooks when is_list(hooks) and hooks != [] ->
        hooks
        |> Enum.reverse()
        |> Enum.each(&run_hook/1)

        drain_hooks()

      _empty_or_missing ->
        :ok
    end
  end

  # Хук выполняется после commit: его падение не должно ни отменять остальные хуки,
  # ни превращать успешную транзакцию в исключение у вызывающего — тот повторил бы
  # уже закоммиченную работу.
  defp run_hook(fun) do
    _ = fun.()
    :ok
  rescue
    e ->
      Logger.error("Хук after-commit упал: #{Exception.format(:error, e, __STACKTRACE__)}")
      :ok
  catch
    kind, reason ->
      Logger.error("Хук after-commit прерван: kind=#{kind} reason=#{inspect(reason)}")
      :ok
  end
end
