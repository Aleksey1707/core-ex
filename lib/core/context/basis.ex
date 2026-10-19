defmodule Core.Context.Basis do
  @moduledoc """
  Основание в `%Context{}` — ключ `:basis_id`: операция события, на которое реагирует
  обработчик.

  Значение получают все события, записанные с этим контекстом (ADR-0081). У операции по запросу
  пользователя основания нет.
  """

  use Core.Context.Accessor,
    key: :basis_id,
    type: Core.Es.Event.OperationID
end
