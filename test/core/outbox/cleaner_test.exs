defmodule Core.Outbox.CleanerTest do
  use Core.DataCase, async: false

  import ExUnit.CaptureLog

  alias Core.Context
  alias Core.Outbox
  alias Core.Outbox.Cleaner
  alias Core.Outbox.Record
  alias Core.Outbox.Repo.Pg.Schema

  @repo Application.compile_env!(:core, Core.Outbox.Repo)

  defmodule FailingRepo do
    @moduledoc false

    def delete_published_before(_before, _context) do
      exit({:noproc, {DBConnection, :checkout, []}})
    end
  end

  setup do
    {:ok, cleaner} =
      start_supervised(
        {Cleaner, repo: @repo, published_ttl: Outbox.PublishedTTL.new!(60), interval_ms: 60_000}
      )

    handler_id = "outbox-cleaner-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:core, :outbox, :cleaner, :cycle],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, cleaner: cleaner, context: Context.new()}
  end

  defp capture_module_logs(module, level, fun) do
    Logger.put_module_level(module, level)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(module)
    end
  end

  test "child_spec: :id равен :name, иначе модуль" do
    assert %{id: Cleaner} = Cleaner.child_spec([])
    assert %{id: :notifications_cleaner} = Cleaner.child_spec(name: :notifications_cleaner)
  end

  test "сбой цикла уходит в backoff, а не долбит БД с полной частотой" do
    {:ok, cleaner} =
      start_supervised(
        {Cleaner,
         repo: FailingRepo,
         published_ttl: Outbox.PublishedTTL.new!(60),
         interval_ms: 60_000,
         retry_min_ms: 30},
        id: :failing_cleaner
      )

    log =
      capture_log(fn ->
        assert {:error, _} = Cleaner.run_once(cleaner)
      end)

    assert log =~ "Сбой цикла очистки outbox: exit"

    # Тик по backoff (30 мс), а не через interval_ms — цикл повторяется сам.
    assert_receive {:telemetry, [:core, :outbox, :cleaner, :cycle], _, %{result: :error}}, 500
    assert Process.alive?(cleaner)
  end

  test "run_once удаляет published старше TTL", %{cleaner: cleaner, context: context} do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("old"),
        %{"n" => "old"}
      )

    :ok = @repo.append([record], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    published =
      Record.mark_published(reserved, Outbox.PublishedAt.now!(), Outbox.UpdatedAt.now!())

    :ok = @repo.save_results([published], context)

    past =
      DateTime.utc_now()
      |> DateTime.add(-3600, :second)
      |> DateTime.truncate(:second)

    from(r in Schema, where: r.id == ^Outbox.ID.format(published.id, :full))
    |> TestRepo.update_all(set: [published_at: past])

    log =
      capture_module_logs(Cleaner, :info, fn ->
        assert :ok = Cleaner.run_once(cleaner)
      end)

    assert log =~ "Очистка outbox: удалено=1 до="

    assert TestRepo.aggregate(
             from(r in Schema, where: r.id == ^Outbox.ID.format(published.id, :full)),
             :count
           ) == 0

    assert_receive {:telemetry, [:core, :outbox, :cleaner, :cycle], measurements, %{result: :ok}}

    assert measurements.deleted == 1
    assert is_integer(measurements.duration)
  end

  test "run_once не удаляет свежие published", %{cleaner: cleaner, context: context} do
    {:ok, record} =
      Record.new(
        Outbox.Topic.new!("products"),
        Outbox.Key.new!("agg-1"),
        Outbox.Name.new!("fresh"),
        %{"n" => "fresh"}
      )

    :ok = @repo.append([record], context)

    [reserved] =
      @repo.fetch_and_reserve(
        Outbox.BatchSize.new!(1),
        Outbox.LockDuration.new!(30),
        context
      )

    published =
      Record.mark_published(reserved, Outbox.PublishedAt.now!(), Outbox.UpdatedAt.now!())

    :ok = @repo.save_results([published], context)

    log =
      capture_module_logs(Cleaner, :info, fn ->
        assert :ok = Cleaner.run_once(cleaner)
      end)

    refute log =~ "Очистка outbox: удалено="

    assert TestRepo.aggregate(
             from(r in Schema, where: r.id == ^Outbox.ID.format(published.id, :full)),
             :count
           ) == 1

    assert_receive {:telemetry, [:core, :outbox, :cleaner, :cycle], measurements, %{result: :ok}}

    assert measurements.deleted == 0
  end
end
