defmodule Core.Helper.Keys do
  @moduledoc """
  Преобразование ключей map: camelCase ↔ snake_case.

  Нужно на границе HTTP: наружу API отдаёт camelCase, домен и wire-профили кодеков
  работают со snake_case.

  `camelize/2` и `snakify/2` — зеркальная пара: обе рекурсивны по map и спискам, обе
  принимают atom- и string-ключи. Ключ на выходе всегда строка: atom не восстанавливается
  обратно, потому что `String.to_atom/1` на данных с границы запрещён (`20-agreements.md`).

  По значениям обе тотальны: struct проходит как есть. Struct — это значение, а не вложенная
  map: разбирать `%DateTime{}` на ключи бессмысленно, а `Map.new/2` на нём падает
  (`Enumerable` не реализован ни у `DateTime`, ни у `Decimal`).

  Опция `except:` — список ключей (atom или строка), которые не преобразуются: регистр ключа
  сохраняется как есть, значение под ним не обходится вовсе. Так проходит free-form нагрузка
  (`metadata`, `payload`), где ключи задаёт не контракт API. Ключ сравнивается со своим
  строковым видом, поэтому `:metadata` в `except:` покрывает и `"metadata"` в данных.

  Перевод atom-ключей в строки без смены регистра — `Core.Helper.Map.stringify_keys/1`.
  """

  @doc """
  Рекурсивно перевести ключи map в camelCase.

  Опции: `except:` — ключи, чьи поддеревья проходят нетронутыми.
  """
  @spec camelize(term(), keyword()) :: term()

  def camelize(term, opts \\ []), do: convert(term, &camelize_key/1, except(opts))

  @doc """
  Рекурсивно перевести ключи map в snake_case.

  Опции: `except:` — ключи, чьи поддеревья проходят нетронутыми.
  """
  @spec snakify(term(), keyword()) :: term()

  def snakify(term, opts \\ []), do: convert(term, &snakify_key/1, except(opts))

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

  # ---

  @spec convert(term(), (atom() | String.t() -> String.t()), MapSet.t(String.t())) :: term()

  defp convert(%_{} = struct, _fun, _except), do: struct

  defp convert(map, fun, except) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if MapSet.member?(except, to_string(key)),
        do: {to_string(key), value},
        else: {fun.(key), convert(value, fun, except)}
    end)
  end

  defp convert(list, fun, except) when is_list(list),
    do: Enum.map(list, &convert(&1, fun, except))

  defp convert(other, _fun, _except), do: other

  @spec except(keyword()) :: MapSet.t(String.t())

  defp except(opts) do
    opts
    |> Keyword.get(:except, [])
    |> MapSet.new(&to_string/1)
  end
end
