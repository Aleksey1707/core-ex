defmodule Core.TestTypes do
  @moduledoc """
  Ecto-типы, которые в приложении-потребителе живут рядом с его `DAO`.

  Библиотека их не предоставляет намеренно: колонка `payload` описывается опцией
  `payload_type:` (`Core.Es.Event.Repo.Pg.Schema`), а её тип — решение хоста.
  """

  defmodule JSON do
    @moduledoc "JSONB любого JSON-значения (object, array, scalar, null)."

    use Ecto.Type

    @doc false
    @impl true
    def type, do: :jsonb

    @doc false
    @impl true
    def cast(value), do: {:ok, value}

    @doc false
    @impl true
    def load(value), do: {:ok, value}

    @doc false
    @impl true
    def dump(value), do: {:ok, value}
  end
end
