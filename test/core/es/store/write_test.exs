defmodule Core.Es.Store.WriteTest do
  use Core.DataCase, async: true

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.Helper.Transact
  alias Core.Outbox
  alias Core.StateStoredFixture

  require Error

  @codec EventFixture.Event.Codec

  describe "append/4" do
    test "операция и сеанс контекста — в событиях потока и записи outbox" do
      id = AggID.new()
      session = Es.Event.SessionID.new!(Ecto.UUID.generate())

      assert :ok = append(path(), [event(id, 1)], Context.Session.put(Context.new(), session))

      assert [%{operation_id: %Es.Event.OperationID{} = operation, session_id: ^session}] =
               Es.Store.Test.events!(@codec, id)

      dumped = Config.codec().dump(operation)
      assert [%{payload: %{"operation_id" => ^dumped}, headers: %{"operation_id" => ^dumped}}] = records(id)
    end

    test "без резервов ключей шаг резервов пропускается, построитель занятого ключа не нужен" do
      id = AggID.new()

      assert :ok = append(path(%{key_reservations: []}), [event(id, 1)], Context.new())
      assert [_] = Es.Store.Test.events!(@codec, id)
    end

    test "отказ записи строится переданным mismatch, транзакция откатывается" do
      id = AggID.new()
      :ok = append(path(), [event(id, 1)], Context.new())

      assert {:error, %Error{ns: :fake, code: :refused, detail: %{expected: 1, actual: 1, source: :storage}}} =
               append(path(), [event(id, 1)], Context.new())

      assert [_] = records(id)
    end

    test "continuous? — поток, начатый не с 1, отвергается" do
      id = AggID.new()

      assert {:error, %Error{code: :refused, detail: %{expected: 2, actual: nil}}} =
               append(path(%{continuous?: true}), [event(id, 2)], Context.new())

      assert :ok = append(path(), [event(id, 2)], Context.new())
    end
  end

  # ---

  defp append(path, events, context),
    do: Transact.run(Config.dao(), fn -> Es.Store.Write.append(path, events, context, []) end)

  defp path(overrides \\ %{}),
    do: Map.merge(%{event_codec: @codec, outbox: StateStoredFixture.Outbox, mismatch: &refused/1}, overrides)

  defp refused(detail),
    do: Error.domain(__MODULE__, code: :refused, ns: :fake, message: "Отказ записи", detail: detail)

  defp event(id, version), do: EventFixture.in_stream(EventFixture.created(), id, version)

  defp records(id) do
    key = Config.codec().dump(id)

    TestRepo.all(from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key, order_by: [asc: r.created_at, asc: r.id]))
  end
end
