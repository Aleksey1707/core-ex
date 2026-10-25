defmodule ConsumerTest.Options do
  @moduledoc "Функция со схемой опций (`use Core.Options`): голова и домен функции остаются авторскими."

  use Core.Options

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Order

  @opts_schema [limit: [type: :pos_integer, default: 1, doc: "Предел."]]
  def take(%Order{} = order, opts \\ []) when is_list(opts), do: {order, Keyword.fetch!(opts, :limit)}

  # состояние другого агрегата в своей функции со схемой
  # expect: incompatible types given to take/2
  def take_foreign(%Account{} = account), do: take(account, limit: 2)

  # проекция не модулем в функции библиотеки со схемой
  # expect: incompatible types given to Core.Es.Projection.run_once/2
  def run_once_name, do: Core.Es.Projection.run_once("activity", batch_size: 1)
end
