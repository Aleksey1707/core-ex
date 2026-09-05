defmodule Core.DAO do
  @moduledoc """
  Билдер `Ecto.Repo` потребителя.

      defmodule MyApp.DAO do
        use Core.DAO,
          otp_app: :my_app,
          adapter: Ecto.Adapters.Postgres
      end

  Это `use Ecto.Repo` плюс обёртка транзакций в `Core.Helper.AfterCommit.wrap/1`.
  Без обёртки after-commit хуки — wake поллера в `Core.Outbox.Repo.append/3` и эталон
  `Repo.Sc` в `Core.Repo.Pg.Es` — молча остаются невыполненными: ошибка не видна ни на
  компиляции, ни в рантайме, а проявляется отложенной доставкой outbox и перезаписью
  всех дочерних строк на каждом `update`.

  Обёрнуты обе точки входа прикладного кода: `transact/1,2` и устаревшая
  `transaction/1,2`. Внутренние транзакции Ecto (`insert` с ассоциациями) идут через
  `adapter.transaction/3`, минуя репозиторий, и под обёртку не попадают.

  ## Opts

  Передаются в `use Ecto.Repo` как есть; обязательны `otp_app:` и `adapter:`.
  """

  alias Core.Helper

  @label "DAO"
  @required_keys ~w(otp_app adapter)a

  @doc "Объявить `Ecto.Repo` потребителя с поддержкой after-commit хуков."
  defmacro __using__(opts) do
    Helper.Opts.require!(opts, @required_keys, @label)

    quote do
      use Ecto.Repo, unquote(opts)

      defoverridable transact: 1, transact: 2, transaction: 1, transaction: 2

      @doc false
      @spec transact(fun() | Ecto.Multi.t(), keyword()) :: {:ok, term()} | {:error, term()}

      def transact(fun_or_multi, opts \\ []) do
        Core.Helper.AfterCommit.wrap(fn -> super(fun_or_multi, opts) end)
      end

      @doc false
      @spec transaction(fun() | Ecto.Multi.t(), keyword()) :: {:ok, term()} | {:error, term()}

      def transaction(fun_or_multi, opts \\ []) do
        Core.Helper.AfterCommit.wrap(fn -> super(fun_or_multi, opts) end)
      end
    end
  end
end
