defmodule Core.Outbox.ReleaseTest do
  use Core.DataCase, async: true

  import Core.EsAggregateRepoContract, only: [write!: 3]
  import Ecto.Query
  import ExUnit.CaptureIO

  alias Core.Config
  alias Core.Context
  alias Core.DerivedFixture
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.EventFixture.Name
  alias Core.EventFixture.PersonID
  alias Core.Outbox
  alias Core.Outbox.Record
  alias Core.Outbox.Release
  alias Core.StateStoredFixture
  alias Core.Version

  @repo Core.Config.outbox_repo()

  @since ~U[2190-01-01 00:00:00Z]

  test "requeue :all возвращает проваленные записи в очередь и сообщает их число оператору" do
    fail_record("f1")
    fail_record("f2")

    assert capture_io(fn -> assert :ok = Release.requeue(:all) end) == "Возвращено в очередь: 2\n"
  end

  test "requeue списка id возвращает только указанные" do
    first = fail_record("f1")
    fail_record("f2")

    assert capture_io(fn -> assert :ok = Release.requeue([first.id]) end) == "Возвращено в очередь: 1\n"
  end

  describe "republish_since" do
    test "пересобранные записи равны записанным, в том числе с запечатанными ПДн" do
      account = Account.ID.new()
      write!(Account.Repo.Pg, account, [open(@since), set_holder("Иван Петров", @since)])
      entity = AggID.new()
      {:ok, _written} = StateStoredFixture.Repo.Pg.insert(entity(entity, [contact_set(entity, @since)]), Context.new())
      written = outbox_rows([account, entity])

      clear_outbox([account, entity])
      capture_io(fn -> assert :ok = Release.republish_since(:core, @since) end)

      assert comparable(outbox_rows([account, entity])) == comparable(written)
      assert [%{status: :new, headers: %{"operation_id" => _}} | _] = outbox_rows([account])
    end

    test "окно — по at: событие раньше since не переопубликуется, ровно в since — да" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(DateTime.add(@since, -1)), rename("Отгрузка", @since)])

      clear_outbox([id])
      capture_io(fn -> Release.republish_since(:core, @since) end)

      assert Enum.map(outbox_rows([id]), & &1.name) == ["account.renamed"]
    end

    test "агрегат без outbox пропускается, итог — по каждому найденному топику" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(@since)])
      derived = AggID.new()
      :ok = Es.Store.append(DerivedFixture.Event.Codec, [tagged(derived, @since)], Context.new(), & &1)

      clear_outbox([id])

      assert capture_io(fn -> Release.republish_since(:core, @since) end) ==
               "Переопубликовано в accounts: 1\nПереопубликовано в fixture: 0\n"

      assert outbox_rows([derived]) == []
    end

    test "приложение, которое не загружается, — ArgumentError с причиной до записи" do
      assert_raise ArgumentError, ~r/приложение :no_such_app не загружено: .*no_such_app\.app/, fn ->
        Release.republish_since(:no_such_app, @since)
      end
    end
  end

  # ---

  defp open(at), do: %Account.Cmd.Open{name: Account.Name.new!("Приёмка"), by: UserID.new(), at: at(at)}

  defp rename(name, at), do: %Account.Cmd.Rename{name: Account.Name.new!(name), by: UserID.new(), at: at(at)}

  defp set_holder(holder, at),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(holder), by: UserID.new(), at: at(at)}

  defp contact_set(id, at) do
    event = EventFixture.contact_set(PersonID.new(), "+7 900 000-00-00", "Звонить после обеда")
    %{EventFixture.in_stream(event, id, 1) | at: at(at)}
  end

  defp entity(id, events) do
    %StateStoredFixture.Entity{
      id: id,
      version: Version.new!(1),
      name: "Приёмка",
      children: %{},
      events: Es.Events.new(events)
    }
  end

  defp tagged(id, at),
    do: DerivedFixture.Event.Tagged.new(Name.new!("Отгрузка"), id, Version.new!(1), ActorID.new(), at(at))

  defp at(at), do: Es.Event.At.new!(at)

  defp outbox_rows(ids) do
    keys = keys(ids)
    TestRepo.all(from(r in Outbox.Repo.Pg.Schema, where: r.key in ^keys, order_by: [asc: r.created_at, asc: r.id]))
  end

  defp clear_outbox(ids) do
    keys = keys(ids)
    TestRepo.delete_all(from(r in Outbox.Repo.Pg.Schema, where: r.key in ^keys))
  end

  defp keys(ids) do
    codec = Config.codec()
    Enum.map(ids, &codec.dump/1)
  end

  defp comparable(rows) do
    Enum.map(rows, fn row ->
      %{
        topic: row.topic,
        key: row.key,
        name: row.name,
        payload: opened(row.payload),
        headers: Map.delete(row.headers, "traceparent")
      }
    end)
  end

  defp opened(payload) do
    {:ok, {[{:ok, {wire, _opened?}}], []}} = Es.Personal.Wire.open_wires([payload], [])
    wire
  end

  defp fail_record(name) do
    context = Context.new()
    {:ok, record} = Record.new(Outbox.Topic.new!("orders"), Outbox.Key.new!("agg-1"), Outbox.Name.new!(name), %{})
    :ok = @repo.append([record], context)

    [reserved] = @repo.fetch_and_reserve(Outbox.BatchSize.new!(1), Outbox.LockDuration.new!(30), context)

    {:ok, message} = Outbox.ErrorMessage.create("nope")
    {:ok, at} = Outbox.UpdatedAt.new(DateTime.utc_now())
    {:ok, failed} = Record.record_failure(reserved, message, Outbox.Attempts.new!(1), at)
    :ok = @repo.save_results([failed], context)

    failed
  end
end
