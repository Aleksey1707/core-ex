defmodule Core.Es.Projection.Supervisor.Mark do
  @moduledoc """
  Отметка дерева проекций на ноде — проверенные опции `Core.Es.Projection.Supervisor` в
  `:persistent_term`. Ставит старт дерева, в том числе `:ignore`; читают ожидание
  `await/3` модуля проекции (список проекций и режим) и пачка (`notifications:`).

  Отметка — отдельный модуль, а не функция супервизора: дерево зависит от читателя, читатель — от
  пачки, и чтение отметки пачкой через супервизор замкнуло бы цикл модулей.
  """

  @doc false
  @spec put(Core.Es.Projection.Supervisor.options()) :: :ok

  def put(%{projections: _projections} = options), do: :persistent_term.put(__MODULE__, options)

  @doc false
  @spec find() :: Core.Es.Projection.Supervisor.options() | nil

  def find, do: :persistent_term.get(__MODULE__, nil)
end
