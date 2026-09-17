defmodule Consumer.S.CallPath do
  @moduledoc "Чужой ID по пути вызова внутри модуля: `defp`, замыкание, обёртка без паттерна."

  alias Consumer.Order
  alias Core.Context
  alias Core.Helper.Transact

  require Core.Config

  @repo Core.Config.repo!(Consumer.Account.Repo)

  # X6 — через `defp`
  # expect: incompatible types given to load/2
  def x6_via_defp(%Order.ID{} = id, %Context{} = context), do: load(id, context)

  # X7 — внутри замыкания `Transact.run`
  def x7_in_closure(%Order.ID{} = id, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.get/3
    do: Transact.run(Consumer.DAO, fn -> @repo.get(id, :current, context) end)

  # X8 — через публичную обёртку без паттерна в том же модуле
  def x8_wrapper(id, context), do: @repo.get(id, :current, context)

  # expect: incompatible types given to x8_wrapper/2
  def x8_via_wrapper(%Order.ID{} = id, %Context{} = context), do: x8_wrapper(id, context)

  # ---

  defp load(id, context), do: @repo.get(id, :current, context)
end

defmodule Consumer.S.Usecase do
  @moduledoc "Usecase с паттерном в голове."

  alias Consumer.Account
  alias Core.Context

  require Core.Config

  @repo Core.Config.repo!(Consumer.Account.Repo)

  def get(%Account.ID{} = id, %Context{} = context), do: @repo.get(id, :current, context)
end

defmodule Consumer.S.Controller do
  @moduledoc "Вызов usecase другого модуля."

  alias Consumer.Order
  alias Consumer.S.Usecase
  alias Core.Context

  # X9 (`get_typed` в карте 02) — чужой ID в usecase с паттерном в голове
  def x9_typed_usecase(%Order.ID{} = id, %Context{} = context),
    # expect: incompatible types given to Consumer.S.Usecase.get/2
    do: Usecase.get(id, context)
end
