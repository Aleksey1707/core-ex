defmodule Core.Helper.Map do
  @moduledoc """
  Хелперы map.

  `field/2` — чтение значения по atom-или-string ключу: JSON из БД приходит со
  строковыми ключами, домен работает с атомами.
  """

  @doc "Значение по atom- или одноимённому string-ключу."
  @spec fetch(map(), atom()) :: {:ok, term()} | :error

  def fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  @doc """
  Фактический ключ, под которым лежит значение: atom или одноимённая строка.

  Нужен тому, кто map не читает, а перезаписывает: класть значение обратно нужно под
  тем же ключом, что нашёлся, иначе map получит оба варианта.
  """
  @spec key(map(), atom()) :: {:ok, atom() | String.t()} | :error

  def key(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:ok, key}
      Map.has_key?(map, string_key) -> {:ok, string_key}
      true -> :error
    end
  end

  @doc "Значение поля map по atom- или string-ключу; иначе `nil`."
  @spec field(map(), atom()) :: term() | nil

  def field(map, key) when is_map(map) and is_atom(key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
