defmodule Core.Es.Aggregate.Process.Execution do
  @moduledoc """
  Исполнение команды процесса агрегата: транзакция «состояние → `Agg.execute/2` → `append` →
  колбэк» и повтор после отказа записи. Транзакцию с повтором держит `Core.Es.Transact` на `dao`
  конфигурации реализации репозитория (ADR-0095), здесь — тело попытки и дедлайн команды: он
  проверяется на обеих границах попытки — до чтения, чтобы попытка после дедлайна не шла, и
  перед commit, чтобы записи после дедлайна не было. Одно на оба режима
  `Core.Es.Aggregate.Process`: в вызывающем процессе (`enabled: false`) решение всегда идёт
  через `get_decision`, в процессе на id (`Core.Es.Aggregate.Process.Server`) закэшированный
  заведённый агрегат дочитывает `refresh`. Исходы — `@moduledoc` `Core.Es.Aggregate.Process`,
  «Команда»: истёкший дедлайн — такая же ошибка вызывающему, как отказ домена или колбэка.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Result
  alias Core.Version

  require Error

  @typedoc """
  Адрес агрегата в span, `dao` транзакции и проверки «вне транзакции», предел повторов и дедлайн
  команды — мс монотонного времени.
  """
  @type target :: %{
          aggregate_id: String.t(),
          dao: module(),
          limit: pos_integer(),
          deadline: integer() | nil
        }

  @typedoc "Фаза дедлайна: ожидание в очереди процесса, чтение состояния и commit."
  @type phase :: :queue | :read | :commit

  # ===== исполнение =====

  @doc """
  Исполнить команду `call` от состояния `cached` (заведённый агрегат — дочитать `refresh`, `nil`
  или незаведённый — решение через `get_decision`): версия после commit или ошибка, состояние
  после commit для кеша процесса (`nil` — commit не было) и число повторов после отказа записи.
  Дедлайн `nil` не проверяется.
  """
  @spec run(
          Core.Es.Aggregate.Process.cfg(),
          Core.Es.Aggregate.Process.call(),
          target(),
          struct() | nil
        ) :: {Result.t(Version.t() | nil), struct() | nil, non_neg_integer()}

  def run(cfg, call, target, cached) when is_struct(cached) or is_nil(cached) do
    {result, retries} =
      Es.Transact.run_counted(fn -> attempt(cfg, call, target, cached) end,
        retries: target.limit,
        dao: target.dao
      )

    {version(result), committed(result), retries}
  end

  # ---

  defp attempt(cfg, call, target, cached) do
    with :ok <- in_time(target, :read),
         {:ok, {events, executed}} <- decided(cfg, call, cached),
         :ok <- cfg.repo.append(events, call.context),
         :ok <- callback(call.fun, events),
         :ok <- in_time(target, :commit) do
      {:ok, executed}
    end
  end

  # Незаведённый агрегат перечитывается `get_decision`: явная версия на пустом потоке сверяется
  # после решения, а `refresh` отказал бы до него.
  defp decided(cfg, call, cached) do
    if refreshes?(cached),
      do: refreshed(cfg, call, cached),
      else: cfg.repo.get_decision(call.id, call.version, call.context, &cfg.aggregate.execute(&1, call.command))
  end

  defp refreshed(cfg, call, cached) do
    cached
    |> cfg.repo.refresh(call.version, call.context)
    |> Result.and_then(&cfg.aggregate.execute(&1, call.command))
  end

  # Состояние наружу не уходит: вызывающий получает версию после commit, на пустом потоке — nil.
  defp version({:ok, %{version: version}}), do: {:ok, version}
  defp version({:error, _reason} = error), do: error

  # Кеш процесса обновляется только commit'ом: отказ оставляет прежнее состояние.
  defp committed({:ok, %{} = state}), do: state
  defp committed({:error, _reason}), do: nil

  defp callback(nil, _events), do: :ok

  # Возврат вне контракта — `CaseClauseError` в транзакции: откат до commit, а не исключение
  # после записи событий.
  defp callback(fun, events) do
    case fun.(events) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Ошибка дедлайна — отказ команды, а не отказ хранилища: цикл повтора её не повторяет, а
  # вызывающий получает её как любой другой исход.
  defp in_time(%{deadline: nil}, _phase), do: :ok

  defp in_time(%{deadline: deadline} = target, phase) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, deadline_error(target, phase)}
  end

  # ===== дедлайн =====

  @doc """
  Ошибка истёкшего дедлайна: `:app` / `:es` / `:deadline_exceeded`, detail —
  `%{aggregate_id: <дамп идентификатора>, phase: :queue | :read | :commit}`. Фазу называет тот,
  кто проверял дедлайн: очередь — `Core.Es.Aggregate.Process.Server`, чтение и commit — попытка.
  """
  @spec deadline_error(target(), phase()) :: Error.t()

  def deadline_error(%{aggregate_id: aggregate_id}, phase) when phase in ~w(queue read commit)a do
    Error.app(
      code: :deadline_exceeded,
      ns: :es,
      message: "Дедлайн команды истёк",
      detail: %{aggregate_id: aggregate_id, phase: phase}
    )
  end

  # ===== вид чтения =====

  @doc """
  Команда от состояния `cached` дочитает его `refresh`: заведённый агрегат. Иначе — полное чтение
  `get_decision`.
  """
  @spec refreshes?(struct() | nil) :: boolean()

  def refreshes?(%{version: %Version{}}), do: true
  def refreshes?(cached) when is_struct(cached) or is_nil(cached), do: false
end
