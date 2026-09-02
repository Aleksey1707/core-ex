defmodule Core.Helper.String do
  @moduledoc """
  Строковые хелперы.

  `first_line/1` — первая непустая строка (`name:` Prim берётся из `@moduledoc`).
  """

  @doc "Первая непустая строка текста (после trim)."
  @spec first_line(String.t()) :: String.t()

  def first_line(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> hd()
  end
end
