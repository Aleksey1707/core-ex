defmodule Core.Outbox.RecordTest do
  use ExUnit.Case, async: true

  alias Core.Outbox
  alias Core.Outbox.Record

  defp sample_record do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("created"),
        %{"x" => 1}
      )

    record
  end

  test "new создаёт запись со статусом :new" do
    record = sample_record()

    assert %Record{
             status: :new,
             attempts: attempts,
             locked_until: nil,
             published_at: nil,
             errors: [],
             updated_at: nil
           } = record

    assert Outbox.Attempts.value(attempts) == 0
    assert Outbox.Topic.value(record.topic) == "products"
  end

  test "reserve переводит в :in_work и увеличивает attempts" do
    record = sample_record()
    locked_until = Outbox.LockedUntil.now!()
    lease_id = Outbox.LeaseID.new()
    at = Outbox.UpdatedAt.now!()

    assert {:ok, reserved} = Record.reserve(record, locked_until, lease_id, at)

    assert reserved.status == :in_work
    assert Outbox.Attempts.value(reserved.attempts) == 1
    assert reserved.locked_until == locked_until
    assert reserved.updated_at == at
  end

  test "mark_published очищает lock" do
    record = sample_record()
    at = Outbox.UpdatedAt.now!()
    published_at = Outbox.PublishedAt.now!()

    assert {:ok, reserved} =
             Record.reserve(record, Outbox.LockedUntil.now!(), Outbox.LeaseID.new(), at)

    published = Record.mark_published(reserved, published_at, at)

    assert published.status == :published
    assert published.published_at == published_at
    assert published.locked_until == nil
  end

  test "release снимает lock без attempts и ошибок" do
    record = sample_record()
    at = Outbox.UpdatedAt.now!()

    assert {:ok, reserved} =
             Record.reserve(record, Outbox.LockedUntil.now!(), Outbox.LeaseID.new(), at)

    attempts = reserved.attempts

    released = Record.release(reserved, at)

    assert released.status == :new
    assert released.locked_until == nil
    assert released.updated_at == at
    assert released.attempts == attempts
    assert released.errors == []
  end

  test "record_failure при attempts < max → :new" do
    record = sample_record()
    at = Outbox.UpdatedAt.now!()

    assert {:ok, reserved} =
             Record.reserve(record, Outbox.LockedUntil.now!(), Outbox.LeaseID.new(), at)

    assert {:ok, message} = Outbox.ErrorMessage.create("boom")

    assert {:ok, failed} =
             Record.record_failure(
               reserved,
               message,
               Outbox.Attempts.new!(3),
               at
             )

    assert failed.status == :new
    assert failed.locked_until == nil
    assert length(failed.errors) == 1
    assert Outbox.Attempt.value(hd(failed.errors).attempt) == 1
  end

  test "record_failure при attempts >= max → :failed" do
    record = sample_record()
    at = Outbox.UpdatedAt.now!()

    assert {:ok, reserved} =
             Record.reserve(record, Outbox.LockedUntil.now!(), Outbox.LeaseID.new(), at)

    assert {:ok, message} = Outbox.ErrorMessage.create("boom")

    assert {:ok, failed} =
             Record.record_failure(
               reserved,
               message,
               Outbox.Attempts.new!(1),
               at
             )

    assert failed.status == :failed
  end

  test "ErrorMessage.create обрезает длинный текст" do
    long = String.duplicate("a", 2500)
    assert {:ok, msg} = Outbox.ErrorMessage.create(long)
    assert String.length(Outbox.ErrorMessage.value(msg)) == 2000
  end

  test "new принимает только JSON-объект в payload" do
    args = [
      Outbox.Topic.new!("products"),
      Outbox.Key.new!("agg-1"),
      Outbox.Name.new!("created")
    ]

    assert {:ok, record} = apply(Record, :new, args ++ [%{"x" => 1}])
    assert record.payload == %{"x" => 1}

    # колонка payload — :map, поэтому не-объект не дошёл бы до записи
    assert_raise FunctionClauseError, fn -> apply(Record, :new, args ++ ["raw-body"]) end
    assert_raise FunctionClauseError, fn -> apply(Record, :new, args ++ [[1, 2]]) end
  end

  test "new принимает headers и created_at" do
    created_at = Outbox.CreatedAt.now!()

    assert {:ok, record} =
             Record.new(
               Outbox.Topic.new!("products"),
               Outbox.Key.new!("agg-1"),
               Outbox.Name.new!("created"),
               %{"x" => 1},
               %{"aggr_id" => "agg-1"},
               created_at
             )

    assert record.headers == %{"aggr_id" => "agg-1"}
    assert record.created_at == created_at
  end
end
