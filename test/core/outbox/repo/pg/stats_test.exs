defmodule Core.Outbox.Repo.Pg.StatsTest do
  use Core.DataCase, async: true

  alias Core.Context
  alias Core.Outbox
  alias Core.Outbox.Record
  alias Core.Outbox.Repo.Pg.Schema
  alias Core.Outbox.Repo.Pg.Stats

  @repo Application.compile_env!(:core, Core.Outbox.Repo)

  setup do
    {:ok, context: Context.new()}
  end

  defp build_record(name) do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!(name),
        %{"n" => name}
      )

    record
  end

  test "counts_by_status возвращает нули на пустой таблице" do
    assert Stats.counts_by_status() == %{
             new: 0,
             in_work: 0,
             published: 0,
             failed: 0
           }
  end

  test "counts_by_status считает по статусам", %{context: context} do
    r1 = build_record("a")
    r2 = build_record("b")
    assert :ok = @repo.append([r1, r2], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    published =
      Record.mark_published(reserved, Outbox.PublishedAt.now!(), Outbox.UpdatedAt.now!())

    :ok = @repo.save_results([published], context)

    assert Stats.counts_by_status() == %{
             new: 1,
             in_work: 0,
             published: 1,
             failed: 0
           }
  end

  test "oldest_age_seconds для :new", %{context: context} do
    assert Stats.oldest_age_seconds(:new) == nil

    record = build_record("old")
    assert :ok = @repo.append([record], context)

    past =
      DateTime.utc_now()
      |> DateTime.add(-120, :second)
      |> DateTime.truncate(:second)

    from(r in Schema, where: r.id == ^Outbox.ID.format(record.id, :full))
    |> TestRepo.update_all(set: [created_at: past])

    age = Stats.oldest_age_seconds(:new)
    assert is_integer(age)
    assert age >= 119
  end

  test "expired_lock_count", %{context: context} do
    assert Stats.expired_lock_count() == 0

    record = build_record("stale")
    assert :ok = @repo.append([record], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    past =
      DateTime.utc_now()
      |> DateTime.add(-120, :second)
      |> DateTime.truncate(:second)

    from(r in Schema, where: r.id == ^Outbox.ID.format(reserved.id, :full))
    |> TestRepo.update_all(set: [locked_until: past, status: "in_work"])

    assert Stats.expired_lock_count() == 1
  end
end
