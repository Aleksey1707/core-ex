defmodule Core.Exc do
  @moduledoc """
  Исключение-обёртка над `%Error{}` для bang-границ.

  Единственный способ поднять доменную/прикладную ошибку: `raise Exc, error`
  (в том числе внутри `Result.unwrap!/1`).

  Текст исключения: у множества ошибок — `Error.format_chain/1` (outer вместе с составом),
  у обычной ошибки — её `to_string/1`. Читатель bang-границы — разработчик в логе.
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
  def message(%__MODULE__{error: %Error{errors: []} = error}) do
    to_string(error)
  end

  def message(%__MODULE__{error: %Error{} = error}) do
    Error.format_chain(error)
  end
end
