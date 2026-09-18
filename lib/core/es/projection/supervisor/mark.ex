defmodule Core.Es.Projection.Supervisor.Mark do
  @moduledoc """
  Отметка дерева проекций на ноде — проверенные опции `Core.Es.Projection.Supervisor` в
  `:persistent_term`. Ставит старт дерева, в том числе `:ignore`; читают ожидание
  `await/3` модуля проекции (список проекций и режим) и пачка (`notifications:`).

  Отметка — отдельный модуль, а не функция супервизора: дерево зависит от читателя, читатель — от
  пачки, и чтение отметки пачкой через супервизор замкнуло бы цикл модулей.

  `fetch!/3` — общая проверка вызывающих: отметки нет — `RuntimeError`, проекция не из
  `projections:` дерева — `ArgumentError`; `label` ставит перед текстом имя вызывающего.
  """

  @doc false
  @spec put(Core.Es.Projection.Supervisor.options()) :: :ok

  def put(%{projections: _projections} = options), do: :persistent_term.put(__MODULE__, options)

  @doc false
  @spec find() :: Core.Es.Projection.Supervisor.options() | nil

  def find, do: :persistent_term.get(__MODULE__, nil)

  @doc false
  @spec fetch!(String.t(), module(), String.t()) :: Core.Es.Projection.Supervisor.options()

  def fetch!(label, projection, name)
      when is_binary(label) and is_atom(projection) and is_binary(name),
      do: listed!(find(), label, projection, name)

  # ---

  defp listed!(nil, label, _projection, _name) do
    raise "#{label}: дерево проекций не запущено — " <>
            "Core.Es.Projection.Supervisor на ноде не стартовал"
  end

  defp listed!(%{projections: projections} = mark, label, projection, name) do
    :ok = ensure_listed!(projection in projections, label, name)
    mark
  end

  defp ensure_listed!(true, _label, _name), do: :ok

  defp ensure_listed!(false, label, name) do
    raise ArgumentError, "#{label}: проекция #{name} не из projections: дерева проекций"
  end
end
