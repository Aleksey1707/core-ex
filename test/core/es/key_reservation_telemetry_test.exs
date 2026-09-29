defmodule Core.Es.KeyReservationTelemetryTest do
  # `:unresolved` воспроизводится подменой `:dao` в окружении приложения — отсюда `async: false`.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [close: 0, execute!: 2, open: 1, write!: 3]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.Telemetry

  require Config

  @repo Config.repo!(Account.KeyedRepo)
  @scope "fixture.name"

  defmodule RefusingDao do
    @moduledoc false

    # Вставка резерва отвергнута, а строк области, которые её отвергли, нет: каждая попытка —
    # «ключ сняли между вставкой и чтением», и повтор исчерпывается.
    def delete_all(_query), do: {0, nil}

    def insert_all(_schema, _rows, _opts) do
      send(self(), :insert)
      {0, nil}
    end

    def all(_query), do: []
  end

  setup do
    handler_id = "key-reservation-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.event([:es, :key_reservation]),
        fn _event, measurements, metadata, test_pid -> send(test_pid, {:reservation, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "резерв своего ключа — :reserved" do
    write!(@repo, Account.ID.new(), [open(unique_name())])

    assert_received {:reservation, %{count: 1}, metadata}
    assert metadata == %{scope: @scope, result: :reserved}
    refute_received {:reservation, _measurements, _metadata}
  end

  test "ключ другого агрегата — :taken" do
    name = unique_name()
    write!(@repo, Account.ID.new(), [open(name)])
    assert_received {:reservation, _measurements, %{result: :reserved}}

    {events, _state} = execute!(%Account{id: Account.ID.new()}, open(name))

    assert {:error, %Error{code: :name_taken}} = @repo.append(events, Context.new())
    assert_received {:reservation, %{count: 1}, metadata}
    assert metadata == %{scope: @scope, result: :taken}
    refute_received {:reservation, _measurements, _metadata}
  end

  test "снятие ключа исходом не считается" do
    write!(@repo, Account.ID.new(), [open(unique_name()), close()])

    assert_received {:reservation, _measurements, %{result: :reserved}}
    refute_received {:reservation, _measurements, _metadata}
  end

  test "неразрешённый резерв — одно событие :unresolved на исход, без значения ключа и aggregate_id" do
    configured = Application.fetch_env!(:core, :dao)
    on_exit(fn -> Application.put_env(:core, :dao, configured) end)
    {events, _state} = execute!(%Account{id: Account.ID.new()}, open(unique_name()))
    Application.put_env(:core, :dao, RefusingDao)

    keys = [Account.NameKey.__es_key_reservation__()]
    taken = &Account.Errors.domain(Account.KeyedRepo, &1, &2)

    assert {:error, %Error{code: :reservation_unresolved}} =
             Es.KeyReservation.append(keys, events, Context.new(), taken)

    assert_received :insert
    assert_received :insert
    assert_received {:reservation, %{count: 1}, metadata}
    assert metadata == %{scope: @scope, result: :unresolved}
    refute_received {:reservation, _measurements, _metadata}
  end

  defp unique_name, do: "Счёт #{System.unique_integer([:positive])}"
end
