defmodule Core.Pagination do
  @moduledoc """
  Доменные примитивы пагинации: limit/offset.
  """

  import Core.Helper.String, only: [first_line: 1]

  alias Core.Prim

  defmodule Limit do
    @moduledoc """
    Размер страницы
    """

    use Prim.Integer,
      name: first_line(@moduledoc),
      min: 1,
      max: 100
  end

  defmodule Offset do
    @moduledoc """
    Смещение страницы
    """

    use Prim.Integer,
      name: first_line(@moduledoc),
      min: 0
  end
end
