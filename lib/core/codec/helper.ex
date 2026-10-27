defmodule Core.Codec.Helper do
  @moduledoc """
  Хелперы load/dump для потребителей entity-фасада (`Core.Codec.Facade.Behaviour`).

  Импортируются в плагины через `use Core.Codec.Plugin`; вызываются с тем же `codec`,
  который плагин получил аргументом.
  """

  alias Core.Codec
  alias Core.Result

  @typedoc "Модуль entity-фасада (`Core.Codec.Facade.Behaviour`)."
  @type codec :: module()

  @doc "Dump опционального значения: `nil` → `nil`."
  @spec dump_optional(struct() | nil, codec()) :: term() | nil

  def dump_optional(nil, _codec), do: nil
  def dump_optional(value, codec) when is_atom(codec), do: codec.dump(value)

  @doc "Dump списка сущностей через `codec.dump/1`."
  @spec dump_many([struct()], codec()) :: [term()]

  def dump_many(list, codec) when is_list(list) and is_atom(codec) do
    Enum.map(list, &codec.dump/1)
  end

  @doc """
  Dump значения **без** Prim-обёртки в формате Prim `mod` (read-модели).

  Значение приводится к своему Prim (`Core.Codec.coerce/2`) и уходит в обычный
  `codec.dump/1` — поэтому формат совпадает с агрегатным путём вплоть до tz, precision
  и переопределений `dump/1` в профиле; plain-kind (`:string`, `:integer`) не исключение.

  Тотальна: `nil`, неприводимое значение и Prim вне `Core.Codec.coercible_kinds/0`
  (кастомный kind) проходят как есть — read-путь не валидирует.
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
  @spec load_optional(module(), term(), codec()) :: Result.t()

  def load_optional(mod, nil, _codec) when is_atom(mod), do: {:ok, nil}

  def load_optional(mod, value, codec) when is_atom(mod) and is_atom(codec) do
    codec.load(mod, value)
  end

  @doc "Load списка сущностей через `codec.load/2`."
  @spec load_many(module(), list(), codec()) :: Result.t(list())

  def load_many(mod, list, codec) when is_atom(mod) and is_list(list) and is_atom(codec) do
    Result.traverse(list, &codec.load(mod, &1))
  end

  # Порядок — по JSON-кодировке wire, а не по терму: терм `%Date{}` и `%Decimal{}` сравнивается по
  # полям struct, а JSON-список уходит строками (ADR-0091).
  @doc false
  @spec set_wire(Enumerable.t()) :: list()

  def set_wire(wires) do
    wires
    |> Enum.map(&{Jason.encode!(&1), &1})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.dedup_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # Ключ объекта — строка: атом enum `Jason` записал бы строкой только при кодировании.
  @doc false
  @spec enum_key(atom()) :: String.t()

  def enum_key(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
end
