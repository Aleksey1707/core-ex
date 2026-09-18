defmodule Core.Es.Aggregate.Process.Execution do
  @moduledoc """
  Исполнение команды процесса агрегата: транзакция «состояние → `Agg.execute/2` → `append` →
  колбэк» и повтор после отказа записи. Транзакцию с повтором держит `Core.Es.Transact`, здесь —
  тело попытки и дедлайн команды: он проверяется на обеих границах попытки — до чтения, чтобы
  попытка после дедлайна не шла, и перед commit, чтобы записи после дедлайна не было. Одно на оба
  режима `Core.Es.Aggregate.Process`: в вызывающем процессе (`enabled: false`) решение всегда идёт
  через `get_decision`, в процессе на id (`Core.Es.Aggregate.Process.Server`) закэшированный
  заведённый агрегат дочитывает `refresh`. Исходы — `@moduledoc` `Core.Es.Aggregate.Process`,
  «Команда».
  """

  alias Core.Es
  alias Core.Result
  alias Core.Version

  @typedoc "Адрес агрегата в span, предел повторов и дедлайн команды — мс монотонного времени."
  @type target :: %{aggregate_id: String.t(), limit: pos_integer(), deadline: integer() | nil}

  @typedoc """
  Исход команды: состояние агрегата после commit, её ошибка или `:expired` — дедлайн истёк до
  commit, и транзакция откатилась.
  """
  @type outcome :: {:ok, struct()} | {:error, term()} | :expired

  @typedoc """
  Результат команды для вызывающего: версия агрегата после commit — `nil`, если команда на пустом
  потоке не дала событий, — или её ошибка.
  """
  @type result :: {:ok, Version.t() | nil} | {:error, term()}

  # ===== исполнение =====

  @doc """
  Исполнить команду `call` от состояния `cached` (заведённый агрегат — дочитать `refresh`, `nil`
  или незаведённый — решение через `get_decision`): исход и число повторов после отказа записи.
  Дедлайн `nil` не проверяется.
  """
  @spec run(
          Core.Es.Aggregate.Process.cfg(),
          Core.Es.Aggregate.Process.call(),
          target(),
          struct() | nil
        ) :: {outcome(), non_neg_integer()}

  def run(cfg, call, target, cached) when is_struct(cached) or is_nil(cached) do
    {result, retries} =
      Es.Transact.run_counted(fn -> attempt(cfg, call, target, cached) end, retries: target.limit)

    {outcome(result), retries}
  end

  # ---

  defp attempt(cfg, call, target, cached) do
    with :ok <- in_time(target.deadline),
         {:ok, {events, executed}} <- decided(cfg, call, cached),
         :ok <- cfg.repo.append(events, call.context),
         :ok <- callback(call.fun, events),
         :ok <- in_time(target.deadline) do
      {:ok, executed}
    end
  end

  # Незаведённый агрегат перечитывается `get_decision`: явная версия на пустом потоке сверяется
  # после решения, а `refresh` отказал бы до него.
  defp decided(cfg, call, %{version: %Version{}} = cached) do
    cached
    |> cfg.repo.refresh(call.version, call.context)
    |> Result.and_then(&cfg.aggregate.execute(&1, call.command))
  end

  defp decided(cfg, call, _uncached_or_unborn) do
    decide = &cfg.aggregate.execute(&1, call.command)
    cfg.repo.get_decision(call.id, call.version, call.context, decide)
  end

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
  # записывает, а попытка после дедлайна не идёт вовсе — `:expired` отказом хранилища не является,
  # и цикл повтора обрывается на ней.
  defp in_time(nil), do: :ok

  defp in_time(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, {__MODULE__, :expired}}
  end

  # Метка дедлайна — с именем модуля: колбэк отдаёт свой `{:error, _}`, и голое
  # `{:error, :expired}` из него неотличимо от служебного.
  defp outcome({:error, {__MODULE__, :expired}}), do: :expired
  defp outcome(result), do: result

  # ===== результат =====

  @doc "Результат команды для вызывающего: версия состояния после commit или её ошибка."
  @spec result({:ok, struct()} | {:error, term()}) :: result()

  def result({:ok, %{version: version}}), do: {:ok, version}
  def result({:error, _reason} = error), do: error
end
