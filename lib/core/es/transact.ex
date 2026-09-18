defmodule Core.Es.Transact do
  @moduledoc """
  Транзакция команды с повтором по источнику отказа записи.

      Es.Transact.run(fn ->
        with {:ok, {events, _account}} <-
               @repo.get_decision(id, version, context, &Account.execute(&1, command)),
             do: @repo.append(events, context)
      end)

  `fun` исполняется в транзакции `Core.Config.dao/0` (`Core.Helper.Transact.run/3`) и, если она
  отказала отказом хранилища, повторяется целиком новой транзакцией — до `retries:` повторов.
  Колбэк MUST быть идемпотентным: при повторе он зовётся заново, включая сопутствующие записи.

  ## Повтор

  Повторяется **отказ хранилища** — `%Error{code: :version_mismatch}` с `source: :storage` в
  detail (`t:Core.Es.Store.mismatch_detail/0`): `Core.Es.Store.append/5` не принял пачку.
  Он не означает, что вызывающий видел устаревшее состояние: голова потока бывает ровно там, где
  он её видел, а отказ дал страж `xid`
  (`docs/adr/0008-shared-event-table-xid8-position.md`, «Цена»).

  Ожидаемая версия в решении о повторе не участвует: сверка при `:current` невозможна, значит
  любая сверка — уже явная версия, и повтор её не исправит. Обоснование —
  `docs/adr/0019-retry-by-write-refusal-source.md`.

  `:storage` несёт и отказ непрерывности потока: у пачки, собранной внутри `fun`, это тот же
  сигнал конкурентной записи, а у пачки от состояния, прочитанного **вне** `run/2`, — разрыв на
  каждой попытке и исчерпание `retries:`. Читать и писать агрегат MUST одна функция под одним
  `run/2` (`docs/rules/20-agreements.md`, «Load/save агрегата — в одной функции»).

  Не повторяются и уходят вызывающему как есть:

  - сверка ожидаемой версии — `source: :expected`, в том числе её список у `get_many`;
  - detail без `source:` — ошибку собрал не write-путь библиотеки;
  - `{:error, reason}`, где `reason` — не `%Core.Error{}`.

  ## Исходы

  - `run/2` — результат `fun`, `run_counted/2` — `{результат, число повторов}` для telemetry
    вызывающего.
  - Повтор — `debug`, исчерпание `retries:` — `warning` и ошибка последней попытки вызывающему.
    Паузы между попытками нет: отказ снимается чужим commit'ом, который уже произошёл.
  - Вызов внутри открытой транзакции — `ArgumentError`: повтор идёт новой транзакцией, и откат
    попытки отменил бы внешнюю.

  ## Opts

  - `retries:` — предел повторов, положительное целое, по умолчанию 3; неизвестная опция или
    недопустимое значение — `ArgumentError`
  """

  alias Core.Config
  alias Core.Error
  alias Core.Helper

  require Logger

  @label "Es.Transact"
  @defaults [retries: 3]

  @doc """
  Исполнить `fun` в транзакции команды с повтором после отказа хранилища: результат `fun`.
  """
  @spec run((-> result), keyword()) :: result when result: var

  def run(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    {result, _retries} = run_counted(fun, opts)
    result
  end

  @doc """
  То же, что `run/2`, плюс число повторов — измерение telemetry вызывающего.
  """
  @spec run_counted((-> result), keyword()) :: {result, non_neg_integer()} when result: var

  def run_counted(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    ensure_outside_transaction!(Config.dao().in_transaction?())
    attempt(fun, retries!(opts), 0)
  end

  # ---

  defp retries!(opts) do
    case Keyword.validate!(opts, @defaults) do
      [retries: retries] when is_integer(retries) and retries > 0 ->
        retries

      [retries: retries] ->
        raise ArgumentError,
              "#{@label}: опция :retries — ожидается положительное целое, получено " <>
                inspect(retries)
    end
  end

  defp ensure_outside_transaction!(false), do: :ok

  defp ensure_outside_transaction!(true) do
    raise ArgumentError,
          "#{@label}: run вызван внутри транзакции — повтор идёт новой транзакцией, и откат " <>
            "попытки отменил бы внешнюю"
  end

  defp attempt(fun, limit, retries) do
    result = Helper.Transact.run(Config.dao(), fun)

    case refusal(result) do
      {:storage, aggregate_id} -> refused(fun, limit, retries, aggregate_id, result)
      :none -> {result, retries}
    end
  end

  # Источник отказа несёт сам detail: место вызова здесь не видно, и отказ соседнего потока в теле
  # команды классифицируется так же, как отказ своего.
  defp refusal({:error, %Error{code: :version_mismatch, detail: detail}}) when is_map(detail),
    do: storage_refusal(detail)

  defp refusal(_result), do: :none

  defp storage_refusal(%{source: :storage, aggregate_id: aggregate_id}),
    do: {:storage, aggregate_id}

  defp storage_refusal(_detail), do: :none

  defp refused(fun, limit, retries, aggregate_id, _result) when retries < limit do
    Logger.debug(
      "транзакция команды: повтор после отказа записи: aggregate_id=#{aggregate_id} " <>
        "retry=#{retries + 1}"
    )

    attempt(fun, limit, retries + 1)
  end

  defp refused(_fun, _limit, retries, aggregate_id, result) do
    Logger.warning(
      "транзакция команды: повторы после отказа записи исчерпаны: " <>
        "aggregate_id=#{aggregate_id} retries=#{retries}"
    )

    {result, retries}
  end
end
