defmodule Core.Version do
  @moduledoc """
  Версия
  """

  import Core.Helper.String, only: [first_line: 1]

  alias Core.Error
  alias Core.Prim
  alias Core.Result

  use Prim.Integer,
    name: first_line(@moduledoc),
    min: 1

  @typedoc """
  Ожидаемая версия: конкретная либо `:current` («любая последняя»).

  Аргумент оптимистичной блокировки в repo-методах и результат `parse/1` (`"*"` → `:current`).
  """
  @type expected :: t() | :current

  @doc "Guard: `expected()` — `%Version{} | :current`."
  defguard is_version(version)
           when version == :current or is_struct(version, __MODULE__)

  @doc "Начальная версия (`1`)."
  @spec new() :: t()

  def new, do: new!(1)

  @doc "Следующая версия."
  @spec next(t()) :: t()

  def next(%__MODULE__{value: value}), do: new!(value + 1)

  @doc "Парсинг: `\"*\"` → `:current`, иначе — `new/1`."
  @spec parse(term()) :: {:ok, expected()} | {:error, Error.t()}

  def parse("*"), do: {:ok, :current}
  def parse(value), do: new(value)

  @doc "Как `parse/1`, при ошибке — `raise Exc`."
  @spec parse!(term()) :: expected()

  def parse!(value), do: Result.unwrap!(parse(value))
end
