defmodule Core.Codec.Helper do
  @moduledoc """
  Хелперы load/dump для потребителей entity-фасада (`Core.Codec.Facade.Behaviour`).

  Импортируются в плагины через `use Core.Codec.Plugin`; вызываются с тем же `codec`,
  который плагин получил аргументом.
  """

  alias Core.Codec
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

  @doc """
  Dump значения **без** Prim-обёртки в формате Prim `mod` (read-модели).

  Значение приводится к своему Prim (`Core.Codec.coerce/2`) и уходит в обычный
  `codec.dump/1` — поэтому формат совпадает с агрегатным путём вплоть до tz, precision
  и переопределений `dump/1` в профиле.

  Тотальна: `nil`, неприводимое значение и Prim, которому приведение не нужно
  (`:string`, `:integer`, кастомный kind), проходят как есть — read-путь не валидирует.
  """
  @spec dump_raw(module(), term(), codec()) :: term()

  def dump_raw(_mod, nil, _codec), do: nil

  def dump_raw(mod, raw, codec) when is_atom(mod) and is_atom(codec) do
    case Codec.coerce(mod, raw) do
      {:ok, prim} -> codec.dump(prim)
      :error -> raw
    end
  end

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
