defmodule Core.Helper.FieldCheck do
  @moduledoc """
  Элементарные compile-time проверки модуля в спеке поля: модуль собран, является Prim,
  является `Core.Enum`; повторы в декларации; общий набор значений `type:` и проверка значения по нему.

  Общие для деклараций полей (`Core.View`, спека полей Codec-плагина, подписи): специфичные
  проверки остаются у каждой декларации. `where` — префикс текста ошибки, по которому видно
  декларацию и поле, без завершающего `:` (`"View: fields: name"`). Отказ — `CompileError` через
  `Core.Helper.Opts.reject!/2`.
  """

  alias Core.Helper.Opts
  alias Core.Prim

  @value Macro.var(:value, __MODULE__)
  @type_checks [
    string: quote(do: is_binary(unquote(@value))),
    boolean: quote(do: is_boolean(unquote(@value))),
    integer: quote(do: is_integer(unquote(@value))),
    pos_integer: quote(do: is_integer(unquote(@value)) and unquote(@value) > 0),
    non_neg_integer: quote(do: is_integer(unquote(@value)) and unquote(@value) >= 0),
    map: quote(do: is_map(unquote(@value)) and not is_struct(unquote(@value)))
  ]

  @doc "Значения `type:`, общие для деклараций полей: скаляры и свободная map."
  @spec type_values() :: [atom()]

  def type_values, do: unquote(Keyword.keys(@type_checks))

  @doc "Проверить, что `value` — значение типа `type` из `type_values/0`; `:map` — map, но не struct."
  @spec type_value?(atom(), term()) :: boolean()

  for {type, check} <- @type_checks do
    def type_value?(unquote(type), unquote(@value)), do: unquote(check)
  end

  @doc "Проверить, что `mod` — собранный модуль."
  @spec module!(term(), String.t()) :: :ok

  def module!(mod, where) when is_atom(mod) do
    case Code.ensure_compiled(mod) do
      {:module, _} -> :ok
      {:error, reason} -> Opts.reject!(where, "#{inspect(mod)} недоступен (#{reason})")
    end
  end

  def module!(other, where) do
    Opts.reject!(where, "ожидается модуль, получено #{inspect(other)}")
  end

  @doc "Проверить, что `mod` — собранный Prim-модуль."
  @spec prim!(term(), String.t()) :: :ok

  def prim!(mod, where) do
    module!(mod, where)

    if not Prim.prim?(mod) do
      Opts.reject!(where, "#{inspect(mod)} не Prim")
    end

    :ok
  end

  @doc "Проверить, что `mod` — собранный модуль `Core.Enum`."
  @spec enum!(term(), String.t()) :: :ok

  def enum!(mod, where) do
    module!(mod, where)

    if not Core.Enum.enum?(mod) do
      Opts.reject!(where, "#{inspect(mod)} не Core.Enum")
    end

    :ok
  end

  @doc "Проверить, что в `values` нет повторов: имена полей, ключи, типы, wire-ключи декларации."
  @spec unique!([term()], String.t()) :: :ok

  def unique!(values, where) when is_list(values) do
    case values -- Enum.uniq(values) do
      [] -> :ok
      repeated -> Opts.reject!(where, "повторяются #{inspect(Enum.uniq(repeated))}")
    end
  end
end
