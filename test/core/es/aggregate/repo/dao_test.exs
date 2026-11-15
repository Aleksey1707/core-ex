defmodule Core.Es.Aggregate.Repo.DaoTest do
  @moduledoc """
  Владелец `dao` команды — реализация репозитория: `repo:` задаёт и транзакцию, и чтение, и
  запись событий с резервами ключей, а guard «внутри транзакции» смотрит на тот же `dao`.

  Репозиторий — `Core.EsFixture.Account.SecondRepo.Pg` на втором тестовом соединении
  `Core.TestRepoSecond` (та же база), `Core.Config.dao/0` — `Core.TestRepo`; резервы проверяет
  `Core.EsFixture.Account.SecondKeyedRepo.Pg`.
  """

  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [open: 1, rename: 1]
  import Ecto.Query, only: [from: 2]

  alias Core.Context
  alias Core.Es.Aggregate.Process
  alias Core.Es.KeyReservation
  alias Core.Es.Store.Schema
  alias Core.EsFixture.Account
  alias Core.Helper.Transact
  alias Core.Version

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Core.TestRepoSecond, shared: false)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      :persistent_term.erase({Process, Account.SecondProcess})
      :persistent_term.erase({Process, Account.SecondKeyedProcess})
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

  describe "резервы ключей на dao команды" do
    test "успешная команда ставит резерв на dao репозитория" do
      start!(Account.SecondKeyedProcess)
      id = Account.ID.new()
      name = unique_name()

      assert {:ok, %Version{}} =
               Account.SecondKeyedProcess.execute(id, :current, open(name), Context.new())

      assert stream_tags(Account.SecondKeyedRepo.Pg, id) == ["account.opened"]
      assert reservations(Account.SecondKeyedRepo.Pg, id) == [[name]]
    end

    test "занятый ключ — отказ без событий и без резерва" do
      start!(Account.SecondKeyedProcess)
      [owner, id] = [Account.ID.new(), Account.ID.new()]
      name = unique_name()
      :ok = occupy(Account.SecondKeyedRepo.Pg, owner, name)

      assert {:error, %Core.Error{module: Account.SecondKeyedRepo, code: :name_taken, detail: %{scope: scope}}} =
               Account.SecondKeyedProcess.execute(id, :current, open(name), Context.new())

      assert scope == "fixture.name"
      assert stream_tags(Account.SecondKeyedRepo.Pg, id) == []
      assert reservations(Account.SecondKeyedRepo.Pg, id) == []
    end

    test "откат колбэка не оставляет ни события, ни резерва" do
      start!(Account.SecondKeyedProcess)
      id = Account.ID.new()
      name = unique_name()
      failed = :callback_failed

      assert {:error, ^failed} =
               Account.SecondKeyedProcess.execute(id, :current, open(name), Context.new(), fn _events ->
                 {:error, failed}
               end)

      assert stream_tags(Account.SecondKeyedRepo.Pg, id) == []
      assert reservations(Account.SecondKeyedRepo.Pg, id) == []
    end
  end

  defp start!(process \\ Account.SecondProcess) do
    %{start: {mod, fun, args}} = process.child_spec(enabled: false)
    :ignore = apply(mod, fun, args)
    :ok
  end

  # Поток событий читается тем же соединением, на котором команда пишет: `__es_read_cfg__/0`
  # реализации — единственный источник `dao` и `codec`.
  defp stream_tags(id), do: stream_tags(Account.SecondRepo.Pg, id)

  defp stream_tags(repo, id) do
    %{dao: dao, codec: codec} = repo.__es_read_cfg__()

    from(e in Schema,
      where: e.aggregate_type == "account" and e.aggregate_id == ^codec.dump(id),
      order_by: [asc: e.aggregate_version],
      select: e.tag
    )
    |> dao.all()
  end

  # Резерв занимает другой агрегат в области названия: строка видна только через `dao`
  # репозитория — та же транзакция, что у команды.
  defp occupy(repo, owner, name) do
    %{dao: dao, codec: codec} = repo.__es_read_cfg__()

    {1, nil} =
      dao.insert_all(KeyReservation.Schema, [
        %{scope: "fixture.name", key: [name], aggregate_id: codec.dump(owner)}
      ])

    :ok
  end

  defp reservations(repo, id) do
    %{dao: dao, codec: codec} = repo.__es_read_cfg__()

    from(r in KeyReservation.Schema, where: r.aggregate_id == ^codec.dump(id), select: r.key)
    |> dao.all()
  end

  defp unique_name, do: "Счёт #{System.unique_integer([:positive])}"
end
