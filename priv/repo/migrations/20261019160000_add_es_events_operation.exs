defmodule Core.TestRepo.Migrations.AddEsEventsOperation do
  @moduledoc """
  Колонки операции, сеанса и основания в `es_events`; DDL — `Core.Es.Migration`.

  Ровно то же пишет у себя приложение с уже выкаченной базой: на свежей базе колонки создаёт
  `up/0` миграции хранилища, и эта миграция ничего не меняет.
  """

  use Ecto.Migration

  def up, do: Core.Es.Migration.add_operation_columns()
  def down, do: :ok
end
