defmodule Core.Mq.Client do
  @moduledoc """
  Проверка, что optional-клиент брокера есть в сборке и адаптер собран вместе с ним.

  Клиенты объявлены `optional: true`, а модули адаптеров обёрнуты в
  `if Code.ensure_loaded?/1` (`10-architecture.md`): без клиента адаптера просто нет.
  Проверка зовётся из `start/2` приложения-потребителя (`Core.Mq.Stream.ensure_available!/0`,
  `Core.Mq.Kafka.ensure_available!/0`) — тогда проблема всплывает понятной ошибкой при
  старте, а не `UndefinedFunctionError` на первом вызове.
  """

  alias Core.Helper.StartOpts

  @label "Core.Mq.Client"

  @doc """
  Проверить пару «клиент → адаптер».

  Опции: `:label` (имя проверяющего модуля для текста), `:client` (модуль клиента),
  `:adapter` (модуль адаптера), `:dep` (atom зависимости), `:requirement` (её версия).
  Различает два случая: клиента нет в сборке вовсе, и клиент есть, но библиотека была
  собрана без него и не пересобрана.
  """
  @spec ensure_available!(keyword()) :: :ok

  def ensure_available!(opts) when is_list(opts) do
    label = StartOpts.binary!(@label, opts, :label)
    dep = StartOpts.atom!(@label, opts, :dep)
    client = StartOpts.module!(@label, opts, :client)
    adapter = StartOpts.module!(@label, opts, :adapter)
    requirement = StartOpts.binary!(@label, opts, :requirement)

    cond do
      not Code.ensure_loaded?(client) ->
        raise ArgumentError, missing_client(label, dep, requirement)

      not Code.ensure_loaded?(adapter) ->
        raise ArgumentError, stale_build(label, dep)

      true ->
        :ok
    end
  end

  # ---

  defp missing_client(label, dep, requirement) do
    "#{label}: клиент #{inspect(dep)} не найден — добавьте " <>
      "{#{inspect(dep)}, #{inspect(requirement)}} в deps приложения (README)"
  end

  defp stale_build(label, dep) do
    "#{label}: клиент #{inspect(dep)} есть, но библиотека собрана без него — " <>
      "пересоберите: mix deps.compile core --force (README)"
  end
end
