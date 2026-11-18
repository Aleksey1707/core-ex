defmodule Core.Es.Personal.State do
  @moduledoc """
  Уничтоженное ПДн-значение в state-stored строке: `%Core.Es.Personal.Destroyed{}` ↔ `{"$pd": null}`.

      holder |> Core.Es.Personal.State.dump()
      row.holder |> Core.Es.Personal.State.load()

  `dump/1` рекурсивно заменяет каждое уничтоженное значение маркером `{"$pd": null}`, `load/1`
  возвращает его обратно. Живое ПДн остаётся открытым: строка mutable, её стирают `update`/`delete`,
  а не шифруют. К хранилищу ключей обе функции не обращаются — `$pd` здесь признак уничтожения,
  а не шифротекст (в wire-форме события тот же ключ несёт base64).

  Маркер — карта ровно с ключом `"$pd"` и значением `nil`; ключ `$pd` в state-stored строке
  зарезервирован. Открытое значение на месте маркера не разбирается.
  """

  alias Core.Es.Personal.Destroyed

  @marker %{"$pd" => nil}

  @doc "Заменить уничтоженные ПДн-значения маркером `{\"$pd\": null}` на любой глубине."
  @spec dump(term()) :: term()

  def dump(%Destroyed{}), do: @marker
  def dump(%_{} = struct), do: struct(struct.__struct__, mapped(Map.from_struct(struct), &dump/1))
  def dump(value) when is_map(value), do: mapped(value, &dump/1)
  def dump(value) when is_list(value), do: Enum.map(value, &dump/1)

  def dump(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&dump/1)
    |> List.to_tuple()
  end

  def dump(value), do: value

  @doc "Вернуть `%Core.Es.Personal.Destroyed{}` на месте маркера `{\"$pd\": null}` на любой глубине."
  @spec load(term()) :: term()

  def load(%{"$pd" => nil} = marker) when map_size(marker) == 1, do: %Destroyed{}
  def load(%_{} = struct), do: struct(struct.__struct__, mapped(Map.from_struct(struct), &load/1))
  def load(value) when is_map(value), do: mapped(value, &load/1)
  def load(value) when is_list(value), do: Enum.map(value, &load/1)

  def load(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&load/1)
    |> List.to_tuple()
  end

  def load(value), do: value

  # ---

  defp mapped(map, fun), do: Map.new(map, fn {key, value} -> {key, fun.(value)} end)
end
