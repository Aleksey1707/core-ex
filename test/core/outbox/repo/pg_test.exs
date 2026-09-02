defmodule Core.Outbox.Repo.PgTest do
  use Core.DataCase, async: true

  alias Core.Context
  alias Core.Outbox
  alias Core.Outbox.Record
  alias Core.Outbox.Repo.Pg.Schema

  @repo Application.compile_env!(:core, Core.Outbox.Repo)

  setup do
    {:ok, context: Context.new()}
  end

  defp build_record(name, created_at \\ nil) do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!(name),
        %{"n" => name},
        nil,
        created_at
      )

    record
  end

  test "append и fetch_and_reserve", %{context: context} do
    r1 = build_record("created")
    r2 = build_record("updated")
    assert :ok = @repo.append([r1, r2], context)

    batch =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(10),
        Outbox.LockDuration.new!(30),
        context
      )

    assert length(batch) == 2
    assert Enum.all?(batch, &(&1.status == :in_work))
    assert Enum.all?(batch, &(Outbox.Attempts.value(&1.attempts) == 1))
    assert Enum.all?(batch, &(&1.locked_until != nil))
  end

  test "fetch_and_reserve не берёт уже заблокированные", %{context: context} do
    records = Enum.map(1..4, fn i -> build_record("e#{i}") end)
    assert :ok = @repo.append(records, context)

    first =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(2),
        Outbox.LockDuration.new!(60),
        context
      )

    second =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(10),
        Outbox.LockDuration.new!(60),
        context
      )

    first_ids = MapSet.new(first, &Outbox.ID.format(&1.id, :full))
    second_ids = MapSet.new(second, &Outbox.ID.format(&1.id, :full))

    assert MapSet.size(first_ids) == 2
    assert MapSet.size(second_ids) == 2
    assert MapSet.disjoint?(first_ids, second_ids)
  end

  test "fetch_and_reserve забирает просроченный in_work", %{context: context} do
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

    [reclaimed] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    assert Outbox.ID.format(reclaimed.id, :full) == Outbox.ID.format(reserved.id, :full)
    assert Outbox.Attempts.value(reclaimed.attempts) == 2
  end

  test "save_results published и failed", %{context: context} do
    record = build_record("pub")
    assert :ok = @repo.append([record], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    at = Outbox.UpdatedAt.now!()
    published = Record.mark_published(reserved, Outbox.PublishedAt.now!(), at)
    assert :ok = @repo.save_results([published], context)

    assert [] ==
             @repo.fetch_and_reserve(
               Outbox.BatchSize.new!(10),
               Outbox.LockDuration.new!(30),
               context
             )

    failed_src = build_record("fail")
    assert :ok = @repo.append([failed_src], context)

    [reserved_fail] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    assert {:ok, message} = Outbox.ErrorMessage.create("nope")

    assert {:ok, failed} =
             Record.record_failure(
               reserved_fail,
               message,
               Outbox.Attempts.new!(1),
               at
             )

    assert failed.status == :failed
    assert :ok = @repo.save_results([failed], context)

    assert [] ==
             @repo.fetch_and_reserve(
               Outbox.BatchSize.new!(10),
               Outbox.LockDuration.new!(30),
               context
             )
  end

  test "delete_published_before удаляет старые published", %{context: context} do
    record = build_record("old")
    assert :ok = @repo.append([record], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    at = Outbox.UpdatedAt.now!()
    published = Record.mark_published(reserved, Outbox.PublishedAt.now!(), at)
    assert :ok = @repo.save_results([published], context)

    past =
      DateTime.utc_now()
      |> DateTime.add(-3600, :second)
      |> DateTime.truncate(:second)

    from(r in Schema, where: r.id == ^Outbox.ID.format(published.id, :full))
    |> TestRepo.update_all(set: [published_at: past])

    assert 1 =
             @repo.delete_published_before(Outbox.PublishedAt.new!(DateTime.utc_now()), context)

    assert TestRepo.aggregate(
             from(r in Schema, where: r.id == ^Outbox.ID.format(published.id, :full)),
             :count
           ) ==
             0
  end

  test "save_results сохраняет errors jsonb", %{context: context} do
    record = build_record("err")
    assert :ok = @repo.append([record], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    at = Outbox.UpdatedAt.now!()

    assert {:ok, message} = Outbox.ErrorMessage.create("delivery failed")

    assert {:ok, with_error} =
             Record.record_failure(
               reserved,
               message,
               Outbox.Attempts.new!(5),
               at
             )

    assert :ok = @repo.save_results([with_error], context)

    [again] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    assert length(again.errors) == 1
    assert Outbox.ErrorMessage.value(hd(again.errors).message) == "delivery failed"
  end

  test "append и save_results чанкуют большие пачки", %{context: context} do
    # > @persist_chunk_size (500) в Repo.Pg
    records = Enum.map(1..520, fn i -> build_record("chunk_#{i}") end)
    assert :ok = @repo.append(records, context)

    batch =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(520),
        Outbox.LockDuration.new!(30),
        context
      )

    assert length(batch) == 520

    at = Outbox.UpdatedAt.now!()
    published = Enum.map(batch, &Record.mark_published(&1, Outbox.PublishedAt.now!(), at))
    assert :ok = @repo.save_results(published, context)

    assert [] ==
             @repo.fetch_and_reserve(
               Outbox.BatchSize.new!(10),
               Outbox.LockDuration.new!(30),
               context
             )
  end

  describe "аренда (lease_id)" do
    test "результат под перехваченной арендой отбрасывается", %{context: context} do
      record = build_record("stolen")
      assert :ok = @repo.append([record], context)

      [first] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(30),
          context
        )

      expire_lease(first)

      [second] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(30),
          context
        )

      refute second.lease_id == first.lease_id

      at = Outbox.UpdatedAt.now!()
      published = Record.mark_published(first, Outbox.PublishedAt.now!(), at)
      assert :ok = @repo.save_results([published], context)

      # Запись осталась за вторым поллером: чужой результат её не тронул.
      assert status_of(first.id) == :in_work

      assert :ok =
               @repo.save_results(
                 [Record.mark_published(second, Outbox.PublishedAt.now!(), at)],
                 context
               )

      assert status_of(first.id) == :published
    end

    test "удалённая запись не воскресает через save_results", %{context: context} do
      record = build_record("deleted")
      assert :ok = @repo.append([record], context)

      [reserved] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(30),
          context
        )

      {1, _} = TestRepo.delete_all(from(r in Schema, where: r.id == ^dump_id(reserved)))

      at = Outbox.UpdatedAt.now!()
      published = Record.mark_published(reserved, Outbox.PublishedAt.now!(), at)
      assert :ok = @repo.save_results([published], context)

      assert TestRepo.aggregate(from(r in Schema, where: r.id == ^dump_id(reserved)), :count) == 0
    end

    test "release возвращает записи в очередь", %{context: context} do
      records = Enum.map(1..2, fn i -> build_record("rel_#{i}") end)
      assert :ok = @repo.append(records, context)

      batch =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(2),
          Outbox.LockDuration.new!(300),
          context
        )

      assert length(batch) == 2
      assert :ok = @repo.release(batch, context)
      assert Enum.all?(batch, &(status_of(&1.id) == :new))

      again =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(2),
          Outbox.LockDuration.new!(30),
          context
        )

      assert length(again) == 2
    end

    test "release под перехваченной арендой не трогает запись", %{context: context} do
      record = build_record("rel_stolen")
      assert :ok = @repo.append([record], context)

      [first] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(30),
          context
        )

      expire_lease(first)

      [_second] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(300),
          context
        )

      assert :ok = @repo.release([first], context)
      assert status_of(first.id) == :in_work
    end
  end

  test "fetch_and_reserve упорядочивает записи с равным created_at по id", %{context: context} do
    created_at = Outbox.CreatedAt.new!(DateTime.utc_now())
    records = Enum.map(1..5, fn i -> build_record("same_#{i}", created_at) end)
    assert :ok = @repo.append(records, context)

    batch =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(5),
        Outbox.LockDuration.new!(30),
        context
      )

    ids = Enum.map(batch, &dump_id/1)
    assert ids == Enum.sort(ids)
  end

  test "fetch_and_reserve фильтрует по topic", %{context: context} do
    {:ok, messages} =
      Record.new(
        Outbox.Topic.new!("messages"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("created"),
        %{"n" => "m"}
      )

    {:ok, notes} =
      Record.new(
        Outbox.Topic.new!("notes"),
        Outbox.Key.new!("owner-1"),
        Outbox.Name.new!("client_notified"),
        %{"n" => "n"}
      )

    assert :ok = @repo.append([messages, notes], context)

    only_notes =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(10),
        Outbox.LockDuration.new!(30),
        {:only, ["notes"]},
        context
      )

    assert Enum.map(only_notes, &Outbox.Name.value(&1.name)) == ["client_notified"]

    except_notes =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(10),
        Outbox.LockDuration.new!(30),
        {:except, ["notes"]},
        context
      )

    assert Enum.map(except_notes, &Outbox.Name.value(&1.name)) == ["created"]
  end

  describe "requeue_failed/2" do
    defp fail_record(name, context) do
      record = build_record(name)
      assert :ok = @repo.append([record], context)

      [reserved] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(30),
          context
        )

      {:ok, message} = Outbox.ErrorMessage.create("nope")
      {:ok, at} = Outbox.UpdatedAt.new(DateTime.utc_now())
      {:ok, failed} = Record.record_failure(reserved, message, Outbox.Attempts.new!(1), at)

      assert failed.status == :failed
      assert :ok = @repo.save_results([failed], context)

      failed
    end

    test ":all возвращает все failed в очередь", %{context: context} do
      fail_record("f1", context)
      fail_record("f2", context)

      assert @repo.requeue_failed(:all, context) == 2

      batch =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(10),
          Outbox.LockDuration.new!(30),
          context
        )

      assert length(batch) == 2
      # attempts сброшены: reserve снова выставил 1-ю попытку
      assert Enum.all?(batch, &(Outbox.Attempts.value(&1.attempts) == 1))
    end

    test "список id возвращает только указанные", %{context: context} do
      first = fail_record("f1", context)
      _second = fail_record("f2", context)

      assert @repo.requeue_failed([first.id], context) == 1

      batch =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(10),
          Outbox.LockDuration.new!(30),
          context
        )

      assert [reserved] = batch
      assert reserved.id == first.id
    end

    test "published-записи не трогает", %{context: context} do
      record = build_record("published")
      assert :ok = @repo.append([record], context)

      [reserved] =
        @repo.fetch_and_reserve(
          Outbox.BatchSize.new!(1),
          Outbox.LockDuration.new!(30),
          context
        )

      {:ok, at} = Outbox.UpdatedAt.new(DateTime.utc_now())
      published = Record.mark_published(reserved, Outbox.PublishedAt.now!(), at)
      assert :ok = @repo.save_results([published], context)

      assert @repo.requeue_failed(:all, context) == 0
    end
  end

  # ---

  defp dump_id(%Record{id: id}), do: Outbox.ID.format(id, :full)

  defp status_of(%Outbox.ID{} = id) do
    TestRepo.one(from(r in Schema, where: r.id == ^Outbox.ID.format(id, :full), select: r.status))
  end

  defp expire_lease(%Record{} = record) do
    past =
      DateTime.utc_now()
      |> DateTime.add(-120, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(r in Schema, where: r.id == ^dump_id(record))
      |> TestRepo.update_all(set: [locked_until: past])

    :ok
  end
end
