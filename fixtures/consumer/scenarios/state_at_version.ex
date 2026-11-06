defmodule ConsumerTest.StateAtVersion do
  @moduledoc """
  Сужение результата read-репозитория состояния на версии до `%AtVersion.View{}` и списка таких
  представлений: опечатка в поле и невозможная clause ловятся компилятором.
  """

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Account.AtVersion.ReadRepo.Pg
  alias Core.Context
  alias Core.Version

  # SAV1 — опечатка в поле `%View{}` результата `get_at`
  def sav1_get_at_typo(%Account.ID{} = id, %Version{} = version, %Context{} = context) do
    with {:ok, view} <- Pg.get_at(id, version, context),
         # expect: unknown key .nmae
         do: view.nmae
  end

  # SAV2 — опечатка в поле элемента результата `get_many_at`
  def sav2_get_many_at_typo(%Account.ID{} = id, %Version{} = version, %Context{} = context) do
    with {:ok, [view | _]} <- Pg.get_many_at([{id, version}], context),
         # expect: unknown key .nmae
         do: view.nmae
  end

  # SAV3 — `:ok` по результату `get_at`
  def sav3_case_get_at_ok(%Account.ID{} = id, %Version{} = version, %Context{} = context) do
    case Pg.get_at(id, version, context) do
      {:ok, view} -> view
      # expect: the following clause will never match
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # SAV4 — `:ok` по результату `get_many_at`
  def sav4_case_get_many_at_ok(%Account.ID{} = id, %Version{} = version, %Context{} = context) do
    case Pg.get_many_at([{id, version}], context) do
      {:ok, views} -> views
      # expect: the following clause will never match
      :ok -> nil
      {:error, _error} -> nil
    end
  end
end
