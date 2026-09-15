defmodule Core.Es.Aggregate.Process.Execution do
  @moduledoc """
  Исполнение команды процесса агрегата: транзакция «состояние → `Agg.execute/2` → `append` →
  колбэк» и повтор после конфликта версии. Одно на оба режима `Core.Es.Aggregate.Process`: в
  вызывающем процессе (`enabled: false`) состояние всегда читает `get`, в процессе на id
  (`Core.Es.Aggregate.Process.Server`) после первого commit — `refresh` от закэшированного.
  Исходы — `@moduledoc` `Core.Es.Aggregate.Process`, «Команда».
  """

  alias Core.Config
  alias Core.Error
  alias Core.Helper.Transact

  require Logger

  @typedoc "Адрес агрегата в логах, предел повторов и дедлайн команды — мс монотонного времени."
  @type target :: %{aggregate_id: String.t(), limit: pos_integer(), deadline: integer() | nil}

  @typedoc """
  Исход команды: состояние агрегата после commit, её ошибка или `:expired` — дедлайн истёк до
  commit, и транзакция откатилась.
  """
  @type outcome :: {:ok, struct()} | {:error, term()} | :expired

  @doc """
  Исполнить команду `call` от состояния `cached` (`nil` — прочитать `get`, иначе дочитать
  `refresh`): исход и число повторов после конфликта версии. Дедлайн `nil` не проверяется.
  """
  @spec run(
          Core.Es.Aggregate.Process.cfg(),
          Core.Es.Aggregate.Process.call(),
          target(),
          struct() | nil
        ) :: {outcome(), non_neg_integer()}

  def run(cfg, call, target, cached) when is_struct(cached) or is_nil(cached),
    do: attempt(cfg, call, target, cached, 0)

  # ---

  # Метки конфликта и дедлайна — с именем модуля: колбэк отдаёт свой `{:error, _}`, и голое
  # `{:error, :expired}` из него неотличимо от служебного.
  defp attempt(cfg, call, target, cached, retries) do
    case transact(cfg, call, target.deadline, cached) do
      {:error, {__MODULE__, :conflict, error}} ->
        conflict(cfg, call, target, cached, retries, error)

      {:error, {__MODULE__, :expired}} ->
        {:expired, retries}

      outcome ->
        {outcome, retries}
    end
  end

  defp transact(cfg, call, deadline, cached) do
    Transact.run(Config.dao(), fn ->
      loaded =
        case cached do
          nil -> cfg.repo.get(call.id, call.version, call.context)
          state -> cfg.repo.refresh(state, call.version, call.context)
        end

      with {:ok, state} <- loaded,
           {:ok, {events, executed}} <- cfg.aggregate.execute(state, call.command),
           :ok <- tag_conflict(cfg.repo.append(events, call.context), call.version),
           :ok <- callback(call.fun, events),
           :ok <- in_time(deadline) do
        {:ok, executed}
      end
    end)
  end

  # Конфликт `append` при `:current` снимается повтором; `%Version{}` мимо головы потока повтор
  # не исправит.
  defp tag_conflict({:error, %Error{code: :version_mismatch} = error}, :current),
    do: {:error, {__MODULE__, :conflict, error}}

  defp tag_conflict(result, _version), do: result

  defp callback(nil, _events), do: :ok

  # Возврат вне контракта — `CaseClauseError` в транзакции: откат до commit, а не исключение
  # после записи событий.
  defp callback(fun, events) do
    case fun.(events) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Вызывающий по истечении дедлайна уже получил exit: команду, которую он не ждёт, commit не
  # записывает.
  defp in_time(nil), do: :ok

  defp in_time(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, {__MODULE__, :expired}}
  end

  defp conflict(cfg, call, target, cached, retries, _error) when retries < target.limit do
    Logger.debug(
      "процесс агрегата: повтор после конфликта версии: type=#{cfg.type} " <>
        "aggregate_id=#{target.aggregate_id} retry=#{retries + 1}"
    )

    attempt(cfg, call, target, cached, retries + 1)
  end

  defp conflict(cfg, _call, target, _cached, retries, error) do
    Logger.warning(
      "процесс агрегата: повторы после конфликта версии исчерпаны: type=#{cfg.type} " <>
        "aggregate_id=#{target.aggregate_id} retries=#{retries}"
    )

    {{:error, error}, retries}
  end

  @doc "Результат команды для вызывающего: `:ok` или её ошибка."
  @spec result({:ok, struct()} | {:error, term()}) :: :ok | {:error, term()}

  def result({:ok, _state}), do: :ok
  def result({:error, _reason} = error), do: error
end
