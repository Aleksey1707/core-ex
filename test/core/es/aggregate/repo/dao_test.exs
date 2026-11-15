defmodule Core.Es.Aggregate.Repo.DaoTest do
  @moduledoc """
  Владелец `dao` команды — реализация репозитория: `repo:` задаёт и транзакцию, и чтение, и
  запись событий, а guard «внутри транзакции» смотрит на тот же `dao`.

  Репозиторий — `Core.EsFixture.Account.SecondRepo.Pg` на втором тестовом соединении
  `Core.TestRepoSecond` (та же база), `Core.Config.dao/0` — `Core.TestRepo`.
  """

  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [open: 1, rename: 1]
  import Ecto.Query, only: [from: 2]

  alias Core.Context
  alias Core.Es.Aggregate.Process
  alias Core.Es.Store.Schema
  alias Core.EsFixture.Account
  alias Core.Helper.Transact
  alias Core.Version

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Core.TestRepoSecond, shared: false)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      :persistent_term.erase({Process, Account.SecondProcess})
    end)

    :ok
  end

  describe "владелец dao команды" do
    test "repo: — команда читает и пишет на dao репозитория; падение колбэка откатывает события" do
      start!()
      id = Account.ID.new()

      assert {:ok, %Version{} = version} =
               Account.SecondProcess.execute(id, :current, open("Счёт"), Context.new())

      assert stream_tags(id) == ["account.opened"]

      failed = :callback_failed

      assert {:error, ^failed} =
               Account.SecondProcess.execute(id, version, rename("Отгрузка"), Context.new(), fn _events ->
                 {:error, failed}
               end)

      assert stream_tags(id) == ["account.opened"]
    end

    test "guard «внутри транзакции» смотрит на dao команды, а не на Core.Config.dao/0" do
      start!()

      assert_raise ArgumentError, ~r/SecondProcess\.execute вызван внутри транзакции/, fn ->
        Transact.run(Core.TestRepoSecond, fn ->
          Account.SecondProcess.execute(Account.ID.new(), :current, open("Счёт"), Context.new())
        end)
      end

      assert {:ok, %Version{}} =
               Transact.run(Core.TestRepo, fn ->
                 Account.SecondProcess.execute(Account.ID.new(), :current, open("Счёт"), Context.new())
               end)
    end
  end

  defp start! do
    %{start: {mod, fun, args}} = Account.SecondProcess.child_spec(enabled: false)
    :ignore = apply(mod, fun, args)
    :ok
  end

  # Поток событий читается тем же соединением, на котором команда пишет: `__es_read_cfg__/0`
  # реализации — единственный источник `dao` и `codec`.
  defp stream_tags(id) do
    %{dao: dao, codec: codec} = Account.SecondRepo.Pg.__es_read_cfg__()

    from(e in Schema,
      where: e.aggregate_type == "account" and e.aggregate_id == ^codec.dump(id),
      order_by: [asc: e.aggregate_version],
      select: e.tag
    )
    |> dao.all()
  end
end
