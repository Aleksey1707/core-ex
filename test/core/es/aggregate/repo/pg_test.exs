defmodule Core.Es.Aggregate.Repo.PgTest do
  use Core.DataCase, async: true
  use Core.EsAggregateRepoContract, impl: Core.EsFixture.Account.Repo.Pg

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.EsFixture.Account
  alias Core.Telemetry

  require Config
  require Error

  @repo Config.repo!(Account.Repo)

  defmodule NoVersionErrors do
    @moduledoc false

    def domain(module, :not_found = code, detail) do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  describe "DI" do
    test "реализация резолвится по конвенции <Behaviour>.Pg" do
      assert @repo == Account.Repo.Pg
    end
  end

  describe "telemetry" do
    test "get — load на вызов и fold на поток" do
      id = Account.ID.new()
      write!(@repo, id, [open(), freeze()])
      attach_telemetry()

      assert {:ok, _state} = @repo.get(id, :current, Context.new())

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2},
                       %{type: "account", snapshot: :off}}

      assert_received {:telemetry, [:core, :es, :aggregate, :load],
                       %{
                         duration: duration,
                         streams: 1,
                         events: 2,
                         snapshot_hit: 0,
                         snapshot_miss: 0,
                         snapshot_rejected: 0
                       }, %{type: "account", op: :get, result: :ok}}

      assert is_integer(duration)
    end

    test "расхождение версии — result: :version_mismatch" do
      id = Account.ID.new()
      attach_telemetry()

      assert {:error, %Error{code: :version_mismatch}} =
               @repo.get(id, Core.Version.new!(1), Context.new())

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 0},
                       %{op: :get, result: :version_mismatch}}
    end

    test "get_many — один load на вызов, fold на каждый поток" do
      [first, second] = [Account.ID.new(), Account.ID.new()]
      write!(@repo, first, [open()])
      write!(@repo, second, [open(), freeze()])
      attach_telemetry()

      assert {:ok, [_, _]} =
               @repo.get_many([{first, :current}, {second, :current}], Context.new())

      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1}, _}
      assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2}, _}

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 2, events: 3},
                       %{op: :get_many, result: :ok}}
    end

    test "refresh — события хвоста после версии состояния" do
      id = Account.ID.new()
      opened = write!(@repo, id, [open()])
      write!(@repo, id, [freeze()])
      attach_telemetry()

      assert {:ok, _state} = @repo.refresh(opened, :current, Context.new())

      assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 1},
                       %{op: :refresh, result: :ok}}
    end

    test "нечитаемый поток — событий нет" do
      id = Account.ID.new()
      {opened, _state} = execute!(%Account{id: id}, open())
      insert_rows!(opened, "account.unknown")
      attach_telemetry()

      assert_raise Core.Exc, fn -> @repo.get(id, :current, Context.new()) end

      refute_received {:telemetry, _event, _measurements, _metadata}
    end
  end

  describe "компиляция" do
    test "требует outbox" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: нет обязательных опций: \[:outbox\]/,
                   fn -> compile!(NoOutbox, outbox: :__drop__) end
    end

    test "кодек событий берётся из агрегата, а не из опции" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: неизвестные опции: \[:event_codec\]/,
                   fn -> compile!(OwnCodec, event_codec: Account.Event.Codec) end
    end

    test "требует clause :version_mismatch в errors" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: errors: отсутствует clause для :version_mismatch/,
                   fn -> compile!(NoVersionMismatch, errors: NoVersionErrors) end
    end

    test "aggregate — event-sourced агрегат" do
      assert_raise CompileError,
                   ~r/aggregate: модуль .* должен экспортировать __es_event_codec__/,
                   fn ->
                     compile!(StateStored, aggregate: Core.StateStoredFixture.Entity)
                   end
    end

    test "Prim агрегата кодека сверяется с id:" do
      message =
        ~r/Prim агрегата Core\.EsFixture\.Account\.ID .* не равен id: Core\.EsFixture\.UserID/

      assert_raise CompileError, message, fn -> compile!(OtherId, id: Core.EsFixture.UserID) end
    end

    test "событие outbox сверяется с семейством кодека" do
      message =
        ~r/outbox: событие Core\.EventFixture\.Event .* семейству кодека .*Account\.Event$/

      assert_raise CompileError, message, fn ->
        compile!(OtherOutbox, outbox: Core.StateStoredFixture.Outbox)
      end
    end

    test "snapshot: — keyword с обязательным every:" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: snapshot: нет обязательных опций: \[:every\]/,
                   fn -> compile!(NoEvery, snapshot: [version: 2]) end

      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: snapshot: ожидается keyword opts, получено true/,
                   fn -> compile!(NotKeyword, snapshot: true) end
    end

    test "snapshot: — неизвестная опция" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: snapshot: неизвестные опции: \[:ttl\]/,
                   fn -> compile!(UnknownSnapshotOpt, snapshot: [every: 2, ttl: 60]) end
    end

    test "snapshot: — every: целое больше нуля, version: целое" do
      assert_raise CompileError,
                   ~r/snapshot: every: ожидается целое больше нуля, получено 0/,
                   fn -> compile!(ZeroEvery, snapshot: [every: 0]) end

      assert_raise CompileError,
                   ~r/snapshot: version: ожидается целое, получено "2"/,
                   fn -> compile!(StringVersion, snapshot: [every: 2, version: "2"]) end
    end

    test "behaviour объявляет колбэки Es.Aggregate.Repo" do
      message = ~r/должен объявлять \[get_many: 3, append: 3, refresh: 4\]/

      assert_raise CompileError, message, fn ->
        compile!(StateStoredBehaviour, behaviour: Core.StateStoredFixture.Repo)
      end
    end
  end

  def handle_telemetry(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
  end

  defp attach_telemetry do
    handler = {__MODULE__, make_ref()}

    events = [
      Telemetry.event([:es, :aggregate, :load]),
      Telemetry.event([:es, :aggregate, :fold])
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp compile!(name, overrides) do
    opts =
      base_opts()
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.Aggregate.Repo.Pg, unquote(opts)
        end
      end
    )
  end

  defp base_opts do
    [
      behaviour: Account.Repo,
      aggregate: Account,
      id: Account.ID,
      errors: Account.Errors,
      outbox: Account.Outbox
    ]
  end
end
