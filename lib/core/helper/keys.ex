defmodule Core.Helper.Keys do
  @moduledoc """
  Преобразование ключей map: camelCase ↔ snake_case.

  Нужно на границе HTTP: наружу API отдаёт camelCase, домен и wire-профили кодеков
  работают со snake_case.

  `camelize/1` и `snakify/1` — зеркальная пара: обе рекурсивны по map и спискам, обе
  принимают atom- и string-ключи. Ключ на выходе всегда строка: atom не восстанавливается
  обратно, потому что `String.to_atom/1` на данных с границы запрещён (`20-agreements.md`).

  По значениям обе тотальны: struct проходит как есть. Struct — это значение, а не вложенная
  map: разбирать `%DateTime{}` на ключи бессмысленно, а `Map.new/2` на нём падает
  (`Enumerable` не реализован ни у `DateTime`, ни у `Decimal`).

  Перевод atom-ключей в строки без смены регистра — `Core.Helper.Map.stringify_keys/1`.
  """

  @doc "Рекурсивно перевести ключи map в camelCase."
  @spec camelize(term()) :: term()

  def camelize(%_{} = struct), do: struct

  def camelize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {camelize_key(key), camelize(value)} end)
  end

  def camelize(list) when is_list(list), do: Enum.map(list, &camelize/1)
  def camelize(other), do: other

  @doc "Рекурсивно перевести ключи map в snake_case."
  @spec snakify(term()) :: term()

  def snakify(%_{} = struct), do: struct

  def snakify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {snakify_key(key), snakify(value)} end)
  end

  def snakify(list) when is_list(list), do: Enum.map(list, &snakify/1)
  def snakify(other), do: other

  @doc "Один ключ → camelCase-строка."
  @spec camelize_key(atom() | String.t()) :: String.t()

  def camelize_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> camelize_key()
  end

  def camelize_key(key) when is_binary(key) do
    case String.split(key, "_") do
      [first | rest] -> first <> Enum.map_join(rest, "", &String.capitalize/1)
    end
  end

  @doc "Один ключ → snake_case-строка."
  @spec snakify_key(atom() | String.t()) :: String.t()

  def snakify_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> snakify_key()
  end

  def snakify_key(key) when is_binary(key) do
    key
    |> String.replace(~r/([A-Z])/, "_\\1")
    |> String.downcase()
    |> String.trim_leading("_")
  end
end
