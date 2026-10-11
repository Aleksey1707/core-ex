defmodule Core.Codec.Facade.Behaviour do
  @moduledoc """
  Контракт entity-фасада: `dump/1`, `load/2`, `load!/2` — и больше никаких функций данных.

  Единственная ось диспетчеризации — модуль: `dump/1` выбирает плагин по `__struct__`,
  `load/2` — по первому аргументу. Полиморфный wire (тег внутри данных) грузится через
  модуль-семейство (`union:` у `Core.Codec.Plugin`), а не отдельной функцией фасада.

  Служебная `__codec_redump__/1` — спека пере-дампа типа для ссылки `{:codec, Type}` у
  `Core.Codec.Redump`: какой плагин обслуживает тип, знает только фасад.
  """

  alias Core.Error

  @callback dump(struct()) :: term()
  @callback load(module(), term()) :: {:ok, term()} | {:error, Error.t()}
  @callback load!(module(), term()) :: term()
  @callback __codec_redump__(module()) :: Core.Codec.Redump.spec()
end
