defmodule Consumer.S do
  @moduledoc """
  Сценарии — намеренно ошибочный код вне раскладки: граница без проверок, и ссылка сценария на
  внутренности `Sales` даёт только предупреждение вывода типов.
  """

  use Boundary,
    check: [in: false, out: false]
end
