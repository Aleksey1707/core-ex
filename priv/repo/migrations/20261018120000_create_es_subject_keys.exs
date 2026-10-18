defmodule Core.TestRepo.Migrations.CreateEsSubjectKeys do
  @moduledoc """
  Таблица ключей субъектов встроенного хранилища ключей; DDL —
  `Core.Es.Personal.KeyStore.Migration`.

  Ровно то же делегирование пишет у себя приложение-потребитель, поэтому тесты библиотеки
  гоняются против его схемы.
  """

  use Ecto.Migration

  defdelegate up, to: Core.Es.Personal.KeyStore.Migration
  defdelegate down, to: Core.Es.Personal.KeyStore.Migration
end
