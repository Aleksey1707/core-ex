defmodule Core.Es.Operation do
  @moduledoc """
  Операция, сеанс инициатора и основание событий записи (ADR-0081).

  `stamp/2` проставляет их событиям до построения записей outbox и до `Core.Es.Store.append`, на
  всех путях записи: репозиторий event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`),
  state-stored агрегат с событиями (`use Core.Repo.Pg.StateStored`), уничтожение ключа субъекта
  (`Core.Es.Personal.destroy_key/3`). Поэтому запись outbox и строка хранилища совпадают.

  | Поле | Источник |
  |---|---|
  | `operation_id` | `Core.Context.Operation`; без него — операция внешней транзакции |
  | `session_id` | `Core.Context.Session`; без него — `nil` |
  | `basis_id` | `Core.Context.Basis`; без него — `nil` |

  Операция внешней транзакции — UUID v7, один на внешнюю транзакцию `DAO`: события нескольких
  агрегатов одной транзакции получают одну операцию. Сбрасывается на commit и rollback
  (`Core.Helper.AfterCommit.get_or_put_in_transaction/2`), поэтому повтор `Core.Es.Transact` —
  новая операция. Вне транзакции — операция на вызов. Наружу сгенерированный id не отдаётся.
  """

  alias Core.Context
  alias Core.Es
  alias Core.Helper.AfterCommit

  @doc "Проставить событиям операцию, сеанс инициатора и основание из `context`."
  @spec stamp([event], Context.t()) :: [event] when event: Es.Event.t()

  def stamp(events, %Context{} = context) when is_list(events) do
    operation = Context.Operation.find(context) || generated()
    session = Context.Session.find(context)
    basis = Context.Basis.find(context)

    Enum.map(events, &%{&1 | operation_id: operation, session_id: session, basis_id: basis})
  end

  # ---

  defp generated,
    do: AfterCommit.get_or_put_in_transaction({__MODULE__, :generated}, &Es.Event.OperationID.new/0)
end
