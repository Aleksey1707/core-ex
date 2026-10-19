defmodule Core.Es.OperationTest do
  use Core.DataCase, async: true

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.EsAggregateRepoContract
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.Helper.Transact
  alias Core.Outbox
  alias Core.Pagination
  alias Core.StateStoredFixture
  alias Core.Version

  require Config
  require Error

  @repo Account.Repo.Pg
  @state_stored Config.repo!(StateStoredFixture.Repo)

  describe "event-sourced агрегат" do
    test "два агрегата одной транзакции — одна операция в событиях, странице потока и outbox" do
      first = Account.ID.new()
      second = Account.ID.new()

      assert {:ok, :done} =
               Transact.run(Config.dao(), fn ->
                 :ok = open!(first, Context.new())
                 :ok = open!(second, Context.new())
                 {:ok, :done}
               end)

      assert [%{operation_id: %Es.Event.OperationID{} = operation, session_id: nil, basis_id: nil}] =
               stored(first)

      assert [%{operation_id: ^operation}] = stored(second)
      assert {:ok, %Pagination.Result{items: [%{operation_id: ^operation}]}} = page(first)

      dumped = Config.codec().dump(operation)

      assert [%{payload: %{"operation_id" => ^dumped} = payload, headers: %{"operation_id" => ^dumped}}] =
               records(first)

      refute Map.has_key?(payload, "session_id")
      refute Map.has_key?(payload, "basis_id")
    end

    test "две транзакции без операции в контексте — разные операции" do
      first = Account.ID.new()
      second = Account.ID.new()

      :ok = open!(first, Context.new())
      :ok = open!(second, Context.new())

      assert [%{operation_id: %Es.Event.OperationID{} = operation}] = stored(first)
      assert [%{operation_id: %Es.Event.OperationID{} = other}] = stored(second)
      assert operation != other
    end

    test "операция, сеанс и основание из контекста" do
      id = Account.ID.new()
      operation = Es.Event.OperationID.new()
      session = Es.Event.SessionID.new!(Ecto.UUID.generate())
      basis = Es.Event.OperationID.new()

      context =
        Context.new()
        |> Context.Operation.put(operation)
        |> Context.Session.put(session)
        |> Context.Basis.put(basis)

      :ok = open!(id, context)

      assert [%{operation_id: ^operation, session_id: ^session, basis_id: ^basis}] = stored(id)

      assert [%{payload: payload, headers: headers}] = records(id)
      assert payload["operation_id"] == Config.codec().dump(operation)
      assert payload["session_id"] == Config.codec().dump(session)
      assert payload["basis_id"] == Config.codec().dump(basis)
      assert headers["operation_id"] == Config.codec().dump(operation)
    end

    test "повтор Es.Transact — новая операция" do
      id = Account.ID.new()
      attempts = :counters.new(1, [])

      assert :ok =
               Es.Transact.run(fn ->
                 :counters.add(attempts, 1, 1)
                 :ok = open!(id, Context.new())
                 [%{operation_id: operation}] = stored(id)
                 send(self(), {:attempt, operation})

                 if :counters.get(attempts, 1) == 1, do: {:error, storage_refusal(id)}, else: :ok
               end)

      assert_received {:attempt, refused}
      assert_received {:attempt, written}
      assert [%{operation_id: ^written}] = stored(id)
      assert refused != written
    end
  end

  describe "state-stored агрегат с событиями" do
    test "операция и сеанс — в событиях потока и записи outbox" do
      id = AggID.new()
      session = Es.Event.SessionID.new!(Ecto.UUID.generate())
      created = EventFixture.in_stream(EventFixture.created(), id, 1)

      assert {:ok, _written} = @state_stored.insert(entity(id, [created]), Context.Session.put(Context.new(), session))

      assert [%{operation_id: %Es.Event.OperationID{} = operation, session_id: ^session}] =
               Es.Store.Test.events!(EventFixture.Event.Codec, id)

      dumped = Config.codec().dump(operation)
      assert [%{payload: %{"operation_id" => ^dumped}, headers: %{"operation_id" => ^dumped}}] = records(id)
    end
  end

  describe "уничтожение ключа субъекта" do
    test "событие уничтожения ключа несёт операцию контекста" do
      subject = Account.ID.new()
      operation = Es.Event.OperationID.new()

      :ok = Personal.destroy_key(subject, UserID.new(), Context.Operation.put(Context.new(), operation))

      subject_id = Personal.SubjectID.new!(Account.ID.value(subject))

      assert [%{operation_id: ^operation}] = Es.Store.Test.events!(Personal.Event.Codec, subject_id)
    end
  end

  # ---

  defp open!(id, context) do
    {:ok, state} = @repo.get(id, :current, context)
    {events, _state} = EsAggregateRepoContract.execute!(state, EsAggregateRepoContract.open())
    @repo.append(events, context)
  end

  defp stored(id), do: Es.Store.Test.events!(Account.Event.Codec, id)

  defp page(id),
    do: @repo.page_stream(id, Pagination.Limit.new!(10), Pagination.Offset.new!(0), Context.new())

  defp records(id) do
    key = Config.codec().dump(id)

    TestRepo.all(from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key, order_by: [asc: r.created_at, asc: r.id]))
  end

  defp storage_refusal(id) do
    Error.domain(__MODULE__,
      code: :version_mismatch,
      ns: :fake,
      message: "Отказ записи",
      detail: %{aggregate_id: Config.codec().dump(id), expected: 1, actual: nil, source: :storage}
    )
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
end
