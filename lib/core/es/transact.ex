defmodule Core.Es.Transact do
  @moduledoc """
  Транзакция команды с повтором по источнику отказа записи.

      Es.Transact.run(fn ->
        with {:ok, {events, _account}} <-
               @repo.get_decision(id, version, context, &Account.execute(&1, command)),
             do: @repo.append(events, context)
      end)

  `fun` исполняется в транзакции `dao:` (`Core.Helper.Transact.run/3`; по умолчанию
  `Core.Config.dao/0`, прочитанный в рантайме вызова) и, если она отказала отказом хранилища,
  повторяется целиком новой транзакцией — до `retries:` повторов.
  Колбэк MUST быть идемпотентным: при повторе он зовётся заново, включая сопутствующие записи.
  Владелец `dao` команды — реализация репозитория агрегата: процесс агрегата передаёт `dao:` из её
  конфигурации (`docs/adr/0095-command-dao-owned-by-repo.md`).

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
  - сверка адреса версии — `source: :address` у `get_at` / `get_many_at`;
  - detail без `source:` — ошибку собрал не write-путь библиотеки;
  - `{:error, reason}`, где `reason` — не `%Core.Error{}`.

  ## Исходы

  - `run/2` — публичный вход: результат `fun`. `run_counted/2` — внутренний вход библиотеки
    (`@doc false`): `{результат, число повторов}` для telemetry процесса агрегата.
  - Повтор — `debug`, исчерпание `retries:` — `warning` и ошибка последней попытки вызывающему.
    Паузы между попытками нет: отказ снимается чужим commit'ом, который уже произошёл.
  - Вызов внутри открытой транзакции `dao:` — `ArgumentError`: повтор идёт новой транзакцией, и
    откат попытки отменил бы внешнюю.
  """

  alias Core.Config
  alias Core.Error
  alias Core.Helper

  require Logger

  use Core.Options

  @label "Es.Transact"
  @opts [
    retries: [type: :pos_integer, default: 3, doc: "Предел повторов после отказа хранилища."],
    dao: [
      type: {:custom, Core.Options.Type, :module, []},
      type_doc: "`module()`",
      doc: "Репозиторий транзакции и проверки «вне транзакции»; по умолчанию `Core.Config.dao/0`."
    ]
  ]

  @opts_schema @opts
  @doc """
  Исполнить `fun` в транзакции команды с повтором после отказа хранилища: результат `fun`.

  ## Опции

  #{Core.Options.docs(@opts_schema)}
  """
  @spec run((-> result), keyword()) :: result when result: var

  def run(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    {result, _retries} = retrying(fun, dao(opts), Keyword.fetch!(opts, :retries))
    result
  end

  @opts_schema @opts
  @doc false
  @spec run_counted((-> result), keyword()) :: {result, non_neg_integer()} when result: var

  def run_counted(fun, opts \\ []) when is_function(fun, 0) and is_list(opts),
    do: retrying(fun, dao(opts), Keyword.fetch!(opts, :retries))

  # ---

  defp dao(opts), do: Config.dao(Keyword.get(opts, :dao))

  defp retrying(fun, dao, limit) do
    ensure_outside_transaction!(dao.in_transaction?())
    attempt(fun, dao, limit, 0)
  end

  defp ensure_outside_transaction!(false), do: :ok

  defp ensure_outside_transaction!(true) do
    raise ArgumentError,
          "#{@label}: run вызван внутри транзакции — повтор идёт новой транзакцией, и откат " <>
            "попытки отменил бы внешнюю"
  end

  defp attempt(fun, dao, limit, retries) do
    result = Helper.Transact.run(dao, fun)

    case refusal(result) do
      {:storage, aggregate_id} -> refused(fun, dao, limit, retries, aggregate_id, result)
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

  defp refused(fun, dao, limit, retries, aggregate_id, _result) when retries < limit do
    Logger.debug(
      "транзакция команды: повтор после отказа записи: aggregate_id=#{aggregate_id} " <>
        "retry=#{retries + 1}"
    )

    attempt(fun, dao, limit, retries + 1)
  end

  defp refused(_fun, _dao, _limit, retries, aggregate_id, result) do
    Logger.warning(
      "транзакция команды: повторы после отказа записи исчерпаны: " <>
        "aggregate_id=#{aggregate_id} retries=#{retries}"
    )

    {result, retries}
  end
end
