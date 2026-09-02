defmodule Core.Codec.Helper do
  @moduledoc """
  Хелперы load/dump для потребителей entity-фасада (`Core.Codec.Facade.Behaviour`).

  Импортируются в плагины через `use Core.Codec.Plugin`; вызываются с тем же `codec`,
  который плагин получил аргументом.
  """

  alias Core.Error
  alias Core.Result

  @typedoc "Модуль entity-фасада (`Core.Codec.Facade.Behaviour`)."
  @type codec :: module()

  @doc "Dump опционального значения: `nil` → `nil`."
  @spec dump_optional(term() | nil, codec()) :: term() | nil

  def dump_optional(nil, _codec), do: nil
  def dump_optional(value, codec), do: codec.dump(value)

  @doc "Dump списка сущностей через `codec.dump/1`."
  @spec dump_many(list(), codec()) :: list()

  def dump_many(list, codec) when is_list(list), do: Enum.map(list, &codec.dump/1)

  @doc "Dump raw-значения по kind (значение без Prim-обёртки): `nil` → `nil`."
  @spec dump_raw_optional(term() | nil, atom(), codec()) :: term() | nil

  def dump_raw_optional(nil, _kind, _codec), do: nil
  def dump_raw_optional(value, kind, codec), do: codec.dump_raw(kind, value)

  @doc "Load опционального Prim: `nil` → `{:ok, nil}`."
  @spec load_optional(term(), module(), codec()) :: {:ok, term()} | {:error, Error.t()}

  def load_optional(nil, _mod, _codec), do: {:ok, nil}
  def load_optional(value, mod, codec), do: codec.load(mod, value)

  @doc "Load списка сущностей через `codec.load/2`."
  @spec load_many(module(), list(), codec()) :: {:ok, list()} | {:error, Error.t()}

  def load_many(mod, list, codec) when is_list(list) do
    Result.traverse(list, &codec.load(mod, &1))
  end
end
