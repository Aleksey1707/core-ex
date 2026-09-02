defmodule Core.Codec.Facade.Behaviour do
  @moduledoc """
  Контракт entity-фасада (`dump` / `load` / `load_tagged` + Prim-профиль).

  `dump_raw/2` — делегат в `dump_raw/2` Prim-профиля: тот же wire-формат для значения
  без Prim-обёртки (read-модели, `<Aggregate>View.Codec`). `dump_raw_as/2` — то же с
  форматом конкретного Prim (kind + tz/precision из его опций типа).
  """

  alias Core.Error

  @callback prim() :: module()
  @callback dump(struct()) :: term()
  @callback dump_raw(atom(), term()) :: term()
  @callback dump_raw_as(module(), term()) :: term()
  @callback load(module(), term()) :: {:ok, term()} | {:error, Error.t()}
  @callback load!(module(), term()) :: term()
  @callback dump_tagged(struct()) :: {term(), term()}
  @callback load_tagged(term(), term()) :: {:ok, term()} | {:error, Error.t()}
  @callback load_tagged!(term(), term()) :: term()
end
