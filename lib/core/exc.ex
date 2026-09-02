defmodule Core.Exc do
  @moduledoc """
  Исключение-обёртка над `%Error{}` для bang-границ.

  Единственный способ поднять доменную/прикладную ошибку: `raise Exc, error`
  (в том числе внутри `Result.unwrap!/1`).
  """

  alias Core.Error

  defexception ~w(error)a

  @doc false
  @impl true
  def exception(%Error{} = error) do
    %__MODULE__{error: error}
  end

  @doc false
  @impl true
  def message(%__MODULE__{error: error}) do
    to_string(error)
  end
end
