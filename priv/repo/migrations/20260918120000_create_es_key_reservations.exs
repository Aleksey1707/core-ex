defmodule Core.TestRepo.Migrations.CreateEsKeyReservations do
  @moduledoc """
  Таблица резервов ключей event-sourced агрегатов; DDL — `Core.Es.KeyReservation.Migration`.

  Ровно то же делегирование пишет у себя приложение-потребитель, поэтому тесты библиотеки
  гоняются против его схемы.
  """

  use Ecto.Migration

  defdelegate up, to: Core.Es.KeyReservation.Migration
  defdelegate down, to: Core.Es.KeyReservation.Migration
end
