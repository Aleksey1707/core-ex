defmodule Core.Context.Operation do
  @moduledoc """
  Операция в `%Context{}` — ключ `:operation_id`.

  Значение из контекста получают все события, записанные с этим контекстом (ADR-0081). Без него
  библиотека создаёт операцию на внешнюю транзакцию сама, и наружу этот id не отдаётся: несколько
  транзакций одного действия делит одна операция, только если usecase положил её сюда.
  """

  use Core.Context.Accessor,
    key: :operation_id,
    type: Core.Es.Event.OperationID
end
