defmodule Core.Mq.Client do
  @moduledoc """
  Проверка, что optional-клиент брокера есть в сборке и адаптер собран вместе с ним.

  Клиенты объявлены `optional: true`, а модули адаптеров обёрнуты в
  `if Code.ensure_loaded?/1` (`10-architecture.md`): без клиента адаптера просто нет.
  Проверка зовётся из `start/2` приложения-потребителя (`Core.Mq.Stream.ensure_available!/0`,
  `Core.Mq.Kafka.ensure_available!/0`) — тогда проблема всплывает понятной ошибкой при
  старте, а не `UndefinedFunctionError` на первом вызове.
  """

  use Core.Options

  @doc """
  Проверить пару «клиент → адаптер».

  Различает два случая: клиента нет в сборке вовсе, и клиент есть, но библиотека была
  собрана без него и не пересобрана.
  """
  @opts_schema [
    label: [
      type: {:custom, Core.Options.Type, :binary, []},
      type_doc: "`t:String.t/0`",
      required: true,
      doc: "Имя проверяющего модуля для текста ошибки."
    ],
    client: [
      type: {:custom, Core.Options.Type, :module, []},
      type_doc: "`t:module/0`",
      required: true,
      doc: "Модуль клиента."
    ],
    adapter: [
      type: {:custom, Core.Options.Type, :module, []},
      type_doc: "`t:module/0`",
      required: true,
      doc: "Модуль адаптера."
    ],
    dep: [
      type: {:custom, Core.Options.Type, :atom, []},
      type_doc: "`t:atom/0`",
      required: true,
      doc: "Имя зависимости клиента."
    ],
    requirement: [
      type: {:custom, Core.Options.Type, :binary, []},
      type_doc: "`t:String.t/0`",
      required: true,
      doc: "Требование к версии зависимости."
    ]
  ]
  @spec ensure_available!(keyword()) :: :ok

  def ensure_available!(opts) when is_list(opts) do
    label = Keyword.fetch!(opts, :label)
    dep = Keyword.fetch!(opts, :dep)
    client = Keyword.fetch!(opts, :client)
    adapter = Keyword.fetch!(opts, :adapter)
    requirement = Keyword.fetch!(opts, :requirement)

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
