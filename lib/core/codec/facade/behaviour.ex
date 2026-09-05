defmodule Core.Codec.Facade.Behaviour do
  @moduledoc """
  Контракт entity-фасада: `dump/1`, `load/2`, `load!/2` — и больше ничего.

  Единственная ось диспетчеризации — модуль: `dump/1` выбирает плагин по `__struct__`,
  `load/2` — по первому аргументу. Полиморфный wire (тег внутри данных) грузится через
  модуль-семейство (`union:` у `Core.Codec.Plugin`), а не отдельной функцией фасада.
  """

  alias Core.Error

  @callback dump(struct()) :: term()
  @callback load(module(), term()) :: {:ok, term()} | {:error, Error.t()}
  @callback load!(module(), term()) :: term()
end
