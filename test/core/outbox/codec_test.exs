defmodule Core.Outbox.CodecTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Outbox
  alias Core.Outbox.Record

  test "record dump/load roundtrip with errors" do
    assert {:ok, record} =
             Record.new(
               Outbox.Topic.new!("products"),
               Outbox.Key.new!("agg-1"),
               Outbox.Name.new!("product_created"),
               %{"event_id" => "1"}
             )

    assert {:ok, record} =
             Record.reserve(
               record,
               Outbox.LockedUntil.now!(),
               Outbox.LeaseID.new(),
               Outbox.UpdatedAt.now!()
             )

    assert {:ok, record} =
             Record.record_failure(
               record,
               Outbox.ErrorMessage.new!("boom"),
               Outbox.Attempts.new!(3),
               Outbox.UpdatedAt.now!()
             )

    dumped = InCodec.dump(record)
    assert dumped.topic == "products"
    assert dumped.status == :new
    assert length(dumped.errors) == 1
    assert hd(dumped.errors).attempt == 1
    assert hd(dumped.errors).message == "boom"

    assert {:ok, loaded} = InCodec.load(Record, dumped)
    assert loaded.id == record.id
    assert loaded.topic == record.topic
    assert loaded.key == record.key
    assert loaded.name == record.name
    assert loaded.payload == record.payload
    assert loaded.status == record.status
    assert loaded.attempts == record.attempts
    assert length(loaded.errors) == 1
    assert hd(loaded.errors).attempt == hd(record.errors).attempt
    assert hd(loaded.errors).message == hd(record.errors).message
  end
end
