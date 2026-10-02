defmodule ConsumerTest do
  @moduledoc """
  Сценарии — намеренно ошибочный код вне раскладки: граница без проверок, как test support
  приложения (`MyAppTest`), и ссылка сценария на внутренности `Sales` даёт только предупреждение
  вывода типов.
  """

  use Boundary,
    check: [in: false, out: false]
end
