defmodule Core.Es.Projection.Test do
  @moduledoc """
  Тестовая поддержка проекций (`Core.Es.Projection`): прогон в процессе теста и подставленная
  пересборка для ветки неготовой read-модели.

  Пачка видит события своей транзакции, поэтому запись через репозиторий и прогон идут в одной
  sandbox-транзакции теста. Тест с прогоном — `async: false`: блокировка пачки и строка чекпоинта
  держатся до конца sandbox-транзакции. ExUnit модуль не использует.
  """

  alias Core.Error
  alias Core.Es.Projection
  alias Core.Es.Projection.Checkpoint
  alias Core.Es.Projection.Supervisor.Mark

  @label "Es.Projection.Test.with_rebuilding"

  # ===== прогон =====

  @doc """
  Прогнать проекции пачками до `:idle` — по очереди, без предела итераций.

  `opts` — опции `Core.Es.Projection.run_once/2`. Пачка с исходом не `:processed` и не `:idle`
  останавливает прогон: `:locked` — `{:error, :locked}`, `:outdated` — `{:error, :outdated}`,
  ошибка — как есть.
  """
  @spec run_until_idle(module() | [module()], keyword()) ::
          :ok | {:error, :locked | :outdated | Error.t()}

  def run_until_idle(projections, opts \\ [])

  def run_until_idle(projections, opts) when is_list(projections) and is_list(opts) do
    Enum.reduce_while(projections, :ok, fn projection, :ok ->
      case until_idle(projection, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def run_until_idle(projection, opts) when is_atom(projection) and is_list(opts),
    do: run_until_idle([projection], opts)

  # ---

  defp until_idle(projection, opts) do
    case Projection.run_once(projection, opts) do
      :processed -> until_idle(projection, opts)
      :idle -> :ok
      :locked -> {:error, :locked}
      :outdated -> {:error, :outdated}
      {:error, %Error{}} = error -> error
    end
  end

  # ===== пересборка =====

  @doc """
  Выполнить `fun`, пока проекции не числятся готовыми, и вернуть его результат.

  `await/3` их модулей отдаёт внутри блока `:projection_rebuilding` сразу, не читая таймаут
  вызывающего: так проверяется ветка ответа на неготовую read-модель (у HTTP-API — 202) без
  ожидания реального времени. Ветка `:projection_timeout` этим хелпером недостижима — её
  проверяют тесты самого ожидания в библиотеке.

  На время блока отметка дерева переводится на `await: :poll`, а строки чекпоинтов названных
  проекций снимаются; в `after` возвращаются и отметка, и строки. Строка встаёт со своей
  позицией и версией, поэтому следующий `run_until_idle/2` досчитывает новые события, а не зовёт
  `clear/0` и не проигрывает историю заново.

  Отметка общая для ноды: на `await: :poll` внутри блока переходят **все** проекции дерева, и
  проекция, которую блок ждёт, но в аргументе не названа, уйдёт в опрос до своего таймаута —
  ждёт блок несколько проекций, MUST называть все.

  Тест MUST быть `async: false`, а снятие строк MUST откатываться sandbox-транзакцией теста.
  Дерево запущено (`enabled: true`) — `ArgumentError`: снятую строку читатели увидели бы как
  начало истории и стёрли read-модель через `clear/0`. Дерево на ноде не стартовало —
  `RuntimeError`; проекция не из `projections:` дерева — `ArgumentError`.

  Отметка и строки возвращаются в `after`, то есть не переживают brutal kill: тест, убитый по
  таймауту ExUnit прямо внутри блока, оставляет отметку на `await: :poll` до конца прогона.
  """
  @spec with_rebuilding(module() | [module()], (-> result)) :: result when result: var

  def with_rebuilding(projections, fun) when is_list(projections) and is_function(fun, 0) do
    pairs = Enum.map(projections, &{&1, &1.__es_projection__()})
    rebuilding(mark!(pairs), Enum.map(pairs, &elem(&1, 1)), fun)
  end

  def with_rebuilding(projection, fun) when is_atom(projection) and is_function(fun, 0),
    do: with_rebuilding([projection], fun)

  # ---

  defp mark!([{projection, declaration} | rest]) do
    mark = Mark.fetch!(@label, projection, declaration.name)
    Enum.each(rest, fn {mod, decl} -> Mark.fetch!(@label, mod, decl.name) end)
    enabled!(mark)
  end

  defp enabled!(%{enabled: false} = mark), do: mark

  defp enabled!(%{enabled: true}) do
    raise ArgumentError,
          "#{@label}: дерево запущено (enabled: true) — снятую строку чекпоинта читатели " <>
            "приняли бы за начало истории и стёрли read-модель через clear/0"
  end

  defp rebuilding(mark, declarations, fun) do
    checkpoints = Enum.map(declarations, &{&1, Checkpoint.find(&1)})
    Enum.each(declarations, &(:ok = Checkpoint.delete(&1)))
    :ok = Mark.put(%{mark | await: :poll})

    try do
      fun.()
    after
      :ok = Mark.put(mark)
      :ok = restore_all(checkpoints)
    end
  end

  defp restore_all(checkpoints) do
    Enum.each(checkpoints, fn {declaration, checkpoint} ->
      :ok = Checkpoint.restore(declaration, checkpoint)
    end)
  end
end
