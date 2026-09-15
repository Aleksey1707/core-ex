defmodule Core.Es.ProjectionTest do
  # Блокировка пачки и строка чекпоинта держатся до конца sandbox-транзакции теста, экспортёр
  # span'ов — глобальный ресурс SDK.
  use Core.DataCase, async: false

  import Core.EsAggregateRepoContract, only: [close: 0, dump: 1, freeze: 0, open: 1, write!: 3]
  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.EventFixture
  alias Core.Helper.Transact
  alias Core.Otel
  alias Core.OtelFixture
  alias Core.StateStoredFixture
  alias Core.StateStoredFixture.Entity
  alias Core.Version
  alias Ecto.Adapters.SQL.Sandbox

  require Config

  @projection EsFixture.Projection
  @account_repo Config.repo!(Account.Repo)
  @entity_repo Config.repo!(StateStoredFixture.Repo)

  defmodule Lone.Event.Done do
    @moduledoc false

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: nil
  end

  defmodule Untyped.Event.Done do
    @moduledoc false

    use Core.Es.Event,
      aggregate_id: Core.EventFixture.AggID,
      by: Core.EventFixture.ActorID,
      payload: nil
  end

  defmodule Untyped.Event.Codec do
    @moduledoc false
  end

  defmodule Twin.Event do
    @moduledoc false

    defmodule Done do
      @moduledoc false

      use Core.Es.Event,
        aggregate_id: Core.EventFixture.AggID,
        by: Core.EventFixture.ActorID,
        payload: nil
    end

    defmodule Stray do
      @moduledoc false

      use Core.Es.Event,
        aggregate_id: Core.EventFixture.AggID,
        by: Core.EventFixture.ActorID,
        payload: nil
    end
  end

  defmodule Twin.Event.Codec do
    @moduledoc false

    use Core.Es.Event.Codec,
      event: Core.Es.ProjectionTest.Twin.Event,
      type: "account",
      tags: %{Core.Es.ProjectionTest.Twin.Event.Done => "twin.done"}
  end

  defmodule RaisingClear do
    @moduledoc false

    use Core.Es.Projection,
      name: "raising_clear",
      events: [Core.EsFixture.Account.Event.Opened],
      version: 2

    @impl true
    def project(_event), do: :ok

    @impl true
    def clear, do: raise(ArgumentError, "очистка сломана")
  end

  defmodule FailingClear do
    @moduledoc false

    require Core.Error

    use Core.Es.Projection,
      name: "failing_clear",
      events: [Core.EsFixture.Account.Event.Opened],
      version: 2

    @impl true
    def project(_event), do: :ok

    # Очистка успевает стереть строки read-модели до отказа: откат пачки их возвращает.
    @impl true
    def clear do
      {_count, nil} = Core.TestRepo.delete_all(Core.EsFixture.Projection.Row)
      {:error, Core.Error.app(code: :clear_failed, ns: :fake)}
    end
  end

  defmodule MovingCheckpoint do
    @moduledoc false

    use Core.Es.Projection,
      name: "moving_checkpoint",
      events: [Core.EsFixture.Account.Event.Opened]

    # Строка своего чекпоинта меняется в обход пачки: CAS по прочитанной строке её не находит.
    @impl true
    def project(_event) do
      sql = "UPDATE es_checkpoints SET version = version + 1 WHERE name = $1"
      %Postgrex.Result{num_rows: 1} = Core.TestRepo.query!(sql, ["moving_checkpoint"])
      :ok
    end

    @impl true
    def clear, do: :ok
  end

  defmodule Bumped do
    @moduledoc false

    # `EsFixture.Projection` новой выкладки: то же имя и read-модель, версия выше.
    use Core.Es.Projection,
      name: "es_fixture",
      events: [
        Core.EsFixture.Account.Event.Opened,
        Core.EsFixture.Account.Event.Closed,
        Core.EventFixture.Event.Created,
        Core.EventFixture.Event.Closed
      ],
      version: 2

    @impl true
    defdelegate project(event), to: Core.EsFixture.Projection

    @impl true
    defdelegate clear, to: Core.EsFixture.Projection
  end

  defmodule DeleteCheckpoint do
    @moduledoc false

    use Ecto.Migration

    def change, do: Core.Es.Migration.delete_checkpoint("es_fixture")
  end

  describe "use" do
    test "объявление: имя, версия по умолчанию, события и потоки по типам агрегатов" do
      declaration = @projection.__es_projection__()

      assert declaration.name == "es_fixture"
      assert declaration.version == 1
      assert declaration.dao == Core.TestRepo
      assert declaration.codec == Config.codec()

      assert declaration.events == [
               Account.Event.Opened,
               Account.Event.Closed,
               EventFixture.Event.Created,
               EventFixture.Event.Closed
             ]

      assert declaration.streams == %{
               "account" => %{
                 codec: Account.Event.Codec,
                 tags: MapSet.new(["account.opened", "account.closed"])
               },
               "fixture" => %{
                 codec: EventFixture.Event.Codec,
                 tags: MapSet.new(["fixture.created", "fixture.closed"])
               }
             }
    end

    test "без project/1 или clear/0 — CompileError" do
      assert_raise CompileError, ~r/обязан объявить project\/1/, fn ->
        compile!(NoProject, [], quote(do: def(clear, do: :ok)))
      end

      assert_raise CompileError, ~r/обязан объявить clear\/0/, fn ->
        compile!(NoClear, [], quote(do: def(project(_event), do: :ok)))
      end
    end

    test "семейство событий в events: — CompileError" do
      assert_raise CompileError, ~r/Account\.Event — семейство событий/, fn ->
        compile!(Family, events: [Account.Event])
      end
    end

    test "модуль события, у кодека которого нет type:, — CompileError" do
      assert_raise CompileError,
                   ~r/Untyped\.Event\.Codec события .* не кодек событий с type:/,
                   fn ->
                     compile!(Untyped, events: [Untyped.Event.Done])
                   end
    end

    test "событие без кодека <Aggregate>.Event.Codec — CompileError" do
      assert_raise CompileError, ~r/кодек .*Lone\.Event\.Codec события .* не найден/, fn ->
        compile!(Lone, events: [Lone.Event.Done])
      end
    end

    test "событие не из tags: своего кодека — CompileError" do
      assert_raise CompileError, ~r/Twin\.Event\.Stray не объявлен в tags:/, fn ->
        compile!(Stray, events: [Twin.Event.Stray])
      end
    end

    test "два кодека одного типа агрегата — CompileError" do
      assert_raise CompileError, ~r/тип агрегата "account" у двух кодеков/, fn ->
        compile!(TwinType, events: [Account.Event.Opened, Twin.Event.Done])
      end
    end

    test "не модуль события — CompileError" do
      assert_raise CompileError, ~r/AggID — не модуль события/, fn ->
        compile!(NotEvent, events: [EventFixture.AggID])
      end

      assert_raise CompileError, ~r/ожидается модуль события, получено "account"/, fn ->
        compile!(NotModule, events: ["account"])
      end
    end

    test "events: пустой или с повтором — CompileError" do
      assert_raise CompileError, ~r/events: ожидается непустой список/, fn ->
        compile!(NoEvents, events: [])
      end

      assert_raise CompileError, ~r/events: модули объявлены дважды/, fn ->
        compile!(Twice, events: [Account.Event.Opened, Account.Event.Opened])
      end
    end

    test "version: не целое ≥ 1 — CompileError" do
      for version <- [0, "1", 1.5] do
        assert_raise CompileError, ~r/version: ожидается целое ≥ 1/, fn ->
          compile!(BadVersion, version: version)
        end
      end
    end

    test "name: не непустая строка — CompileError" do
      for name <- ["", :es_fixture] do
        assert_raise CompileError, ~r/name: ожидается непустая строка/, fn ->
          compile!(BadName, name: name)
        end
      end
    end

    test "нет обязательных и неизвестная опция — CompileError" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:events\]/, fn ->
        compile!(NoEventsOpt, events: :__drop__)
      end

      assert_raise CompileError, ~r/неизвестные опции: \[:batch_size\]/, fn ->
        compile!(UnknownOpt, batch_size: 10)
      end
    end
  end

  describe "run_once/2" do
    test "первая пачка — старт с начала: clear/0 и чекпоинт в начале истории со своей версией" do
      insert_row!("account", Account.ID.new(), "Сирота")

      log = capture_info(fn -> assert :processed = Es.Projection.run_once(@projection) end)

      assert rows() == []

      assert checkpoint!() == %{
               xid: nil,
               number: nil,
               version: 1,
               target_xid: nil,
               target_number: nil
             }

      assert log =~ "старт с начала истории: projection=es_fixture from_version=nil to_version=1"

      # событий нет — цель пуста, и пересборку завершает та же пачка
      assert log =~ "цель пересборки достигнута: projection=es_fixture version=1"
      assert :idle = Es.Projection.run_once(@projection)
    end

    test "события после чекпоинта пачками до batch_size" do
      ids = for _ <- 1..3, do: Account.ID.new()
      Enum.each(ids, &write!(@account_repo, &1, [open("Счёт")]))

      assert :processed = Es.Projection.run_once(@projection, batch_size: 2)
      assert :processed = Es.Projection.run_once(@projection, batch_size: 2)
      assert length(rows()) == 2
      assert :processed = Es.Projection.run_once(@projection, batch_size: 2)
      assert length(rows()) == 3
      assert :idle = Es.Projection.run_once(@projection, batch_size: 2)
    end

    test "тег, известный кодеку, но не объявленный, — пропуск без загрузки, чекпоинт движется" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт"), freeze()])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      checkpoint = checkpoint!()

      insert_event!(account, 3, "account.renamed", %{"name" => ""})

      assert :processed = Es.Projection.run_once(@projection)
      assert :idle = Es.Projection.run_once(@projection)
      assert rows() == [{"account", dump(account), "Счёт", false}]
      refute checkpoint!() == checkpoint
    end

    test "тег источника upcasts: объявленного модуля — апкаст и project/1" do
      account = Account.ID.new()
      insert_event!(account, 1, "account.opened.v1", %{"title" => "Старое имя"})

      assert :ok = Es.Projection.Test.run_until_idle(@projection)

      assert rows() == [{"account", dump(account), "Старое имя", false}]
    end

    test "объявленный тег с нечитаемой нагрузкой — ошибка загрузки без сдвига чекпоинта" do
      insert_event!(Account.ID.new(), 1, "account.opened", %{"name" => ""})
      assert :processed = Es.Projection.run_once(@projection)
      checkpoint = checkpoint!()

      assert {:error, %Error{kind: :domain}} = Es.Projection.run_once(@projection)
      assert checkpoint!() == checkpoint
    end

    test "тег, неизвестный кодеку, — :unknown_event_type без сдвига чекпоинта" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      insert_event!(account, 2, "account.unknown", nil)
      assert :processed = Es.Projection.run_once(@projection)
      checkpoint = checkpoint!()

      assert {:error, %Error{code: :unknown_event_type}} = Es.Projection.run_once(@projection)
      assert {:error, %Error{code: :unknown_event_type}} = Es.Projection.run_once(@projection)
      assert checkpoint!() == checkpoint
      assert rows() == []
    end

    test "{:error, _} project/1 — откат пачки; после починки read-модели события не потеряны" do
      account = Account.ID.new()
      entity = EventFixture.AggID.new()
      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      checkpoint = checkpoint!()
      TestRepo.delete_all(EsFixture.Projection.Row)

      insert_entity!(entity, "Агрегат")
      write!(@account_repo, account, [close()])

      assert {:error, %Error{kind: :app, ns: :es_fixture, code: :stream_not_found}} =
               Es.Projection.run_once(@projection)

      assert rows() == []
      assert checkpoint!() == checkpoint

      insert_row!("account", account, "Счёт")
      assert :ok = Es.Projection.Test.run_until_idle(@projection)

      assert Enum.sort(rows()) == [
               {"account", dump(account), "Счёт", true},
               {"fixture", dump(entity), "Агрегат", false}
             ]
    end

    test "исключение project/1 — прикладная ошибка с модулем исключения, текст — в warning" do
      entity = EventFixture.AggID.new()
      insert_entity!(entity, "Агрегат")
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      checkpoint = checkpoint!()
      TestRepo.delete_all(EsFixture.Projection.Row)
      close_entity!(entity, "Агрегат")

      log =
        capture_log(fn ->
          assert {:error, %Error{kind: :app, ns: :es, code: :projection_raised} = error} =
                   Es.Projection.run_once(@projection)

          assert error.message == nil

          assert error.detail == %{
                   projection: "es_fixture",
                   callback: :project,
                   exception: MatchError
                 }
        end)

      assert log =~ "projection=es_fixture callback=project"
      assert log =~ "MatchError"
      assert checkpoint!() == checkpoint
    end

    test "ошибка и исключение clear/0 — откат: строка чекпоинта не записана" do
      assert {:error, %Error{code: :clear_failed}} = Es.Projection.run_once(FailingClear)
      assert checkpoint!("failing_clear") == nil

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :projection_raised} = error} =
                   Es.Projection.run_once(RaisingClear)

          assert error.detail == %{
                   projection: "raising_clear",
                   callback: :clear,
                   exception: ArgumentError
                 }
        end)

      assert log =~ "очистка сломана"
      assert checkpoint!("raising_clear") == nil
    end

    test "пачку проекции держит другое соединение — :locked" do
      assert :processed = Es.Projection.run_once(@projection)

      assert :locked = in_other_connection(fn -> Es.Projection.run_once(@projection) end)
    end

    test "строка чекпоинта изменилась в обход пачки — :checkpoint_conflict и откат" do
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      assert :processed = Es.Projection.run_once(MovingCheckpoint)

      assert {:error, %Error{kind: :app, ns: :es, code: :checkpoint_conflict}} =
               Es.Projection.run_once(MovingCheckpoint)

      assert %{xid: nil, number: nil, version: 1} = checkpoint!("moving_checkpoint")
    end

    test "внутри транзакции — ArgumentError" do
      assert_raise ArgumentError, ~r/внутри транзакции/, fn ->
        Transact.run(TestRepo, fn -> Es.Projection.run_once(@projection) end)
      end
    end
  end

  describe "пересборка" do
    test "ручной DELETE строки чекпоинта — старт с начала и прогон истории заново" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      %{xid: xid, number: number} = checkpoint!()
      TestRepo.query!("DELETE FROM es_checkpoints WHERE name = $1", ["es_fixture"])

      log = capture_info(fn -> assert :processed = Es.Projection.run_once(@projection) end)

      assert log =~ "projection=es_fixture from_version=nil to_version=1"
      assert rows() == []

      assert checkpoint!() == %{
               xid: nil,
               number: nil,
               version: 1,
               target_xid: xid,
               target_number: number
             }

      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      assert rows() == [{"account", dump(account), "Счёт", false}]
    end

    test "ошибка и исключение clear/0 при подъёме version: — откат, строка чекпоинта прежняя" do
      account = Account.ID.new()
      :ok = insert_row!("account", account, "Счёт")
      :ok = insert_checkpoint!("failing_clear", 1, {100, 5})
      :ok = insert_checkpoint!("raising_clear", 1, {100, 5})

      assert {:error, %Error{code: :clear_failed}} = Es.Projection.run_once(FailingClear)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :projection_raised}} = Es.Projection.run_once(RaisingClear)
        end)

      assert log =~ "очистка сломана"

      for name <- ["failing_clear", "raising_clear"] do
        assert checkpoint!(name) == %{
                 xid: 100,
                 number: 5,
                 version: 1,
                 target_xid: nil,
                 target_number: nil
               }
      end

      assert rows() == [{"account", dump(account), "Счёт", false}]
    end

    test "версия строки чекпоинта выше version: — :outdated, события не читаются" do
      write!(@account_repo, Account.ID.new(), [open("Счёт")])
      :ok = insert_checkpoint!("es_fixture", 2)

      assert :outdated = Es.Projection.run_once(@projection)
      assert {:error, :outdated} = Es.Projection.Test.run_until_idle(@projection)

      assert rows() == []

      assert checkpoint!() == %{
               xid: nil,
               number: nil,
               version: 2,
               target_xid: nil,
               target_number: nil
             }
    end

    test "подъём version: — clear/0, чекпоинт в начало с целью и прогон истории заново до цели" do
      [first, second] = for _ <- 1..2, do: Account.ID.new()
      write!(@account_repo, first, [open("Счёт")])
      write!(@account_repo, second, [open("Второй")])

      # последнее событие хранилища — чужого типа: цель — последнее событие типов проекции
      insert_event!(Account.ID.new(), 1, "foreign.done", nil, "foreign")
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      %{xid: xid, number: number} = checkpoint!()
      TestRepo.update_all(EsFixture.Projection.Row, set: [name: "Прошлый прогон"])

      log = capture_info(fn -> assert :processed = Es.Projection.run_once(Bumped) end)

      assert log =~ "projection=es_fixture from_version=1 to_version=2"
      assert rows() == []

      assert checkpoint!() == %{
               xid: nil,
               number: nil,
               version: 2,
               target_xid: xid,
               target_number: number
             }

      assert :outdated = Es.Projection.run_once(@projection)

      log =
        capture_info(fn -> assert :processed = Es.Projection.run_once(Bumped, batch_size: 1) end)

      refute log =~ "цель пересборки достигнута"

      log =
        capture_info(fn -> assert :processed = Es.Projection.run_once(Bumped, batch_size: 1) end)

      assert log =~ "цель пересборки достигнута: projection=es_fixture version=2"

      assert :idle = Es.Projection.run_once(Bumped)
      assert %{xid: ^xid, number: ^number, version: 2} = checkpoint!()

      assert Enum.sort(rows()) ==
               Enum.sort([
                 {"account", dump(first), "Счёт", false},
                 {"account", dump(second), "Второй", false}
               ])
    end
  end

  describe "Migration.delete_checkpoint/1" do
    test "миграция потребителя удаляет строку чекпоинта своей проекции, чужие остаются" do
      :ok = insert_checkpoint!("es_fixture", 1, {100, 5})
      :ok = insert_checkpoint!("failing_clear", 2)

      # Блокировка миграций держит соединение sandbox, которого ждёт процесс миграции.
      assert :ok =
               Ecto.Migrator.up(TestRepo, 20_260_914_150_000, DeleteCheckpoint,
                 log: false,
                 migration_lock: false
               )

      assert checkpoint!() == nil

      assert checkpoint!("failing_clear") == %{
               xid: nil,
               number: nil,
               version: 2,
               target_xid: nil,
               target_number: nil
             }
    end
  end

  describe "Test.run_until_idle/2" do
    test "запись через репозитории обоих видов → read-модель в порядке записи" do
      account = Account.ID.new()
      entity = EventFixture.AggID.new()

      write!(@account_repo, account, [open("Счёт")])
      insert_entity!(entity, "Агрегат")
      write!(@account_repo, account, [close()])
      close_entity!(entity, "Агрегат")

      assert :ok = Es.Projection.Test.run_until_idle(@projection)

      assert Enum.sort(rows()) == [
               {"account", dump(account), "Счёт", true},
               {"fixture", dump(entity), "Агрегат", true}
             ]

      assert :idle = Es.Projection.run_once(@projection)
    end

    test "список проекций по очереди; первая ошибка останавливает прогон" do
      assert {:error, %Error{code: :clear_failed}} =
               Es.Projection.Test.run_until_idle([@projection, FailingClear])

      assert checkpoint!() != nil
    end

    test "пачку держит другое соединение — {:error, :locked}" do
      assert :processed = Es.Projection.run_once(@projection)

      assert {:error, :locked} =
               in_other_connection(fn -> Es.Projection.Test.run_until_idle(@projection) end)
    end
  end

  describe "span" do
    setup do
      :ok = OtelFixture.attach()
      :ok
    end

    test "старт с начала — project <имя> с reset и без позиций" do
      assert :processed = Es.Projection.run_once(@projection)

      project = OtelFixture.drain() |> OtelFixture.find("project es_fixture")

      assert project.kind == :internal

      assert project.attributes == %{
               "core.es.projection.name" => "es_fixture",
               "core.es.projection.version" => 1,
               "core.es.projection.reset" => true,
               "core.es.batch.event_count" => 0
             }
    end

    test "пачка событий — корневой span с числом событий и чекпоинтом до и после" do
      account = Account.ID.new()
      write!(@account_repo, account, [open("Счёт")])
      assert :ok = Es.Projection.Test.run_until_idle(@projection)
      from = checkpoint!()
      _spans = OtelFixture.drain()

      write!(@account_repo, account, [freeze()])
      Otel.span("usecase", [], fn -> assert :processed = Es.Projection.run_once(@projection) end)

      spans = OtelFixture.drain()
      project = OtelFixture.find(spans, "project es_fixture")
      to = checkpoint!()

      assert project.parent_span_id == :undefined
      refute project.trace_id == OtelFixture.find(spans, "usecase").trace_id

      assert project.attributes == %{
               "core.es.projection.name" => "es_fixture",
               "core.es.projection.version" => 1,
               "core.es.projection.reset" => false,
               "core.es.batch.event_count" => 1,
               "core.es.checkpoint.from" => "#{from.xid}/#{from.number}",
               "core.es.checkpoint.to" => "#{to.xid}/#{to.number}"
             }
    end

    test "отказ на событии — core.es.event.id и статус ошибки" do
      account = Account.ID.new()
      assert :processed = Es.Projection.run_once(@projection)
      event_id = insert_event!(account, 1, "account.unknown", nil)
      _spans = OtelFixture.drain()

      assert {:error, _error} = Es.Projection.run_once(@projection)

      project = OtelFixture.drain() |> OtelFixture.find("project es_fixture")

      assert project.attributes["core.es.event.id"] == event_id
      assert project.attributes["error.type"] == "es/unknown_event_type"
      assert {:error, _message} = project.status
      refute Map.has_key?(project.attributes, "core.es.checkpoint.to")
    end

    test "холостая и заблокированная пачки span'а не дают" do
      assert :processed = Es.Projection.run_once(@projection)
      _spans = OtelFixture.drain()

      assert :idle = Es.Projection.run_once(@projection)
      assert :locked = in_other_connection(fn -> Es.Projection.run_once(@projection) end)

      assert OtelFixture.drain(50) == []
    end
  end

  defp compile!(name, overrides, body \\ nil) do
    opts =
      [name: "compile_test", events: [Account.Event.Opened]]
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    body =
      body ||
        quote do
          def project(_event), do: :ok
          def clear, do: :ok
        end

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.Projection, unquote(opts)

          unquote(body)
        end
      end
    )
  end

  # Уровень логов тестов — `:warning`: `info` пачки виден только с уровнем её модуля.
  defp capture_info(fun) do
    Logger.put_module_level(Es.Projection.Batch, :info)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(Es.Projection.Batch)
    end
  end

  # Отдельное соединение вне sandbox: блокировку пачки видит, но записанного тестом — нет.
  defp in_other_connection(fun) do
    Task.async(fn -> Sandbox.unboxed_run(TestRepo, fun) end)
    |> Task.await()
  end

  defp insert_entity!(id, name) do
    event = EventFixture.in_stream(EventFixture.created(name), id, 1)
    {:ok, _entity} = @entity_repo.insert(entity(id, 1, name, [event]), Context.new())
    :ok
  end

  defp close_entity!(id, name) do
    event = EventFixture.in_stream(EventFixture.closed(), id, 2)
    {:ok, _entity} = @entity_repo.update(entity(id, 2, name, [event]), Context.new())
    :ok
  end

  defp entity(id, version, name, events) do
    %Entity{
      id: id,
      version: Version.new!(version),
      name: name,
      children: %{},
      events: Es.Events.new(events)
    }
  end

  # Строка `es_events` в обход репозитория: тип агрегата, тег и нагрузку задаёт тест.
  defp insert_event!(account, version, tag, payload, type \\ "account") do
    event_id = dump(Es.Event.ID.new())

    row = %{
      aggregate_type: type,
      aggregate_id: dump(account),
      aggregate_version: version,
      event_id: event_id,
      tag: tag,
      payload: payload,
      by_id: dump(EsFixture.UserID.new()),
      at: DateTime.utc_now(:second)
    }

    {1, nil} = TestRepo.insert_all(Es.Store.Schema, [row])
    event_id
  end

  defp insert_row!(type, id, name) do
    row = %{aggregate_type: type, aggregate_id: dump(id), name: name, closed: false}
    {1, nil} = TestRepo.insert_all(EsFixture.Projection.Row, [row])
    :ok
  end

  defp rows do
    from(r in EsFixture.Projection.Row,
      order_by: [r.aggregate_type],
      select: {r.aggregate_type, r.aggregate_id, r.name, r.closed}
    )
    |> TestRepo.all()
  end

  defp checkpoint!(name \\ "es_fixture") do
    sql =
      "SELECT xid, number, version, target_xid, target_number FROM es_checkpoints WHERE name = $1"

    case TestRepo.query!(sql, [name]).rows do
      [] ->
        nil

      [[xid, number, version, target_xid, target_number]] ->
        %{
          xid: xid,
          number: number,
          version: version,
          target_xid: target_xid,
          target_number: target_number
        }
    end
  end

  defp insert_checkpoint!(name, version, {xid, number} \\ {nil, nil}) do
    sql = "INSERT INTO es_checkpoints (name, xid, number, version) VALUES ($1, $2, $3, $4)"
    %Postgrex.Result{num_rows: 1} = TestRepo.query!(sql, [name, xid, number, version])
    :ok
  end
end
