defmodule Core.Context.Session do
  @moduledoc """
  Сеанс инициатора в `%Context{}` — ключ `:session_id`.

  Кладёт приложение — своим web-плагом: что считать сеансом, библиотека не знает (ADR-0081).
  Значение получают все события, записанные с этим контекстом; у операции Системы сеанса нет.
  """

  use Core.Context.Accessor,
    key: :session_id,
    type: Core.Es.Event.SessionID
end
