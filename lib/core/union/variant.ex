defmodule Core.Union.Variant do
  @moduledoc false

  # Вариант семейства (`Core.Union`): модуль, адрес как объявлен, нормализованное место
  # (`Core.Codec.Plugin.Variants.place/0`) и вид значения — Prim, декларативная структура или тип
  # с ручным Codec.

  @enforce_keys ~w(module address place kind)a
  defstruct @enforce_keys

  @typedoc "Вид варианта: `:prim`, `:domain` (декларативная структура) или `:manual`."
  @type kind :: :prim | :domain | :manual

  @type t :: %__MODULE__{
          module: module(),
          address: term(),
          place: term(),
          kind: kind()
        }
end
