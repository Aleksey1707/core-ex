defmodule Core.Repo.Pg.StateStoredTest do
  use Core.DataCase, async: true

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal.Destroyed
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.EventFixture.Contact
  alias Core.EventFixture.PersonID
  alias Core.Outbox
  alias Core.Pagination
  alias Core.Repo
  alias Core.StateStoredFixture
  alias Core.StateStoredFixture.Child
  alias Core.StateStoredFixture.Entity
  alias Core.StateStoredFixture.Profile
  alias Core.Telemetry
  alias Core.Version

  require Config
  require Error

  @codec EventFixture.Event.Codec
  @repo Config.repo!(StateStoredFixture.Repo)
  @contact "+7 900 000-00-00"

  defmodule ReadOnlyBehaviour do
    @moduledoc false

    use Core.Repo, only: :read
  end

  defmodule NoEventsEntity do
    @moduledoc false

    use Core.Struct, fields: [id: [prim: Core.EventFixture.AggID]]
  end

  defmodule ForeignEventsEntity do
    @moduledoc false

    use Core.Struct,
      fields: [id: [prim: Core.EventFixture.AggID]],
      events: Core.EsFixture.Account.Event
  end

  defmodule SoloChild do
    @moduledoc false

    use Ecto.Schema

    @primary_key false

    schema "fixture_solo_children" do
      field :entity_id, :binary_id, primary_key: true
      field :name, :string
    end

    def to_models(_entity), do: []
  end

  defmodule StrictErrors do
    @moduledoc false

    def domain(module, code, detail)
        when code in ~w(not_found version_mismatch incomplete_result no_ids)a do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  defmodule NoVersionErrors do
    @moduledoc false

    def domain(module, code, detail) when code in ~w(not_found incomplete_result no_ids)a do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  defmodule AccountOutbox do
    @moduledoc false

    use Core.Es.Outbox,
      topic: "fixture",
      family: Core.EsFixture.Account.Event
  end

  defmodule OverridingRepo do
    @moduledoc "Write-behaviour агрегата для репозитория с переопределёнными `insert`/`update`."

    use Core.Repo,
      only: ~w(get insert update save)a,
      entity: Core.StateStoredFixture.Entity,
      id: Core.EventFixture.AggID
  end

  defmodule OverridingRepo.Pg do
    @moduledoc "Репозиторий, переопределивший только `insert`/`update`: `save` обязан пройти через них."

    alias Core.EventFixture
    alias Core.StateStoredFixture.Child
    alias Core.StateStoredFixture.Entity
    alias Core.StateStoredFixture.Schema

    use Core.Repo.Pg.StateStored,
      behaviour: Core.Repo.Pg.StateStoredTest.OverridingRepo,
      schema: Schema,
      to_entity: &Schema.to_entity!/1,
      to_model: &Schema.to_model!/1,
      to_id: &Schema.dump_id/1,
      query: Schema.base_query(),
      shadow_copy?: true,
      id: EventFixture.AggID,
      entity: Entity,
      errors: EventFixture.Errors,
      event_codec: EventFixture.Event.Codec,
      outbox: Core.StateStoredFixture.Outbox,
      children: [[schema: Child, fk: :entity_id]]

    def insert(entity, context, opts) do
      send(self(), :insert_via_override)
      super(entity, context, opts)
    end

    def update(entity, context, opts) do
      send(self(), :update_via_override)
      super(entity, context, opts)
    end
  end

  describe "компиляция" do
    test "требует event_codec и outbox" do
      assert_raise CompileError,
                   ~r/Repo\.Pg\.StateStored: нет обязательных опций: \[:event_codec, :outbox\]/,
                   fn -> compile!(NoCodec, event_codec: :__drop__, outbox: :__drop__) end
    end

    test "требует entity и id" do
      assert_raise CompileError,
                   ~r/Repo\.Pg\.StateStored: нет обязательных опций: \[:entity, :id\]/,
                   fn -> compile!(NoEntity, entity: :__drop__, id: :__drop__) end
    end

    test "опечатка в ключе — одна ошибка при раскрытии, с меткой Repo.Pg" do
      assert_raise CompileError, ~r/^Repo\.Pg: неизвестные опции: \[:childrens\]$/, fn ->
        compile!(BadOwnOpt, [childrens: []], quote(do: raise("тело вычислено")))
      end
    end

    test "атрибут в event_codec: — «ожидается литерал»" do
      message = ~r/^Repo\.Pg\.StateStored: event_codec: ожидается литерал, получено @codec$/

      assert_raise CompileError, message, fn ->
        compile!(AttrCodec, [event_codec: quote(do: @codec)], quote(do: @codec(unquote(@codec))))
      end
    end

    test "to_entity: — выражение, проверяется в теле Repo.Pg, с меткой" do
      message = ~r/^Repo\.Pg: to_entity: ожидается захват функции арности 1 .*, получено 1$/

      assert_raise CompileError, message, fn ->
        compile!(IntMapper, [to_entity: quote(do: @mapper)], quote(do: @mapper(1)))
      end
    end

    test "event_codec — кодек событий с type:" do
      assert_raise CompileError,
                   ~r/event_codec: Core\.EventFixture\.Event — не кодек событий с type:/,
                   fn -> compile!(NotCodec, event_codec: EventFixture.Event) end
    end

    test "Prim агрегата кодека сверяется с id:" do
      message =
        ~r/event_codec: Prim агрегата Core\.EventFixture\.AggID .* не равен id: .*\.ActorID/

      assert_raise CompileError, message, fn -> compile!(OtherId, id: EventFixture.ActorID) end
    end

    test "семейство кодека называет владельцем потока другую сущность — CompileError" do
      message =
        "Repo.Pg.StateStored: event_codec: семейство Core.EventFixture.Event объявляет aggregate: " <>
          "Core.StateStoredFixture.Entity, а не Core.EsFixture.Account"

      assert_raise CompileError, message, fn -> compile!(OtherOwner, entity: Core.EsFixture.Account) end
    end

    test "entity: — структура по полям без events: — CompileError" do
      message =
        "Repo.Pg.StateStored: entity: Core.Repo.Pg.StateStoredTest.NoEventsEntity — структура по полям " <>
          "без events: — события агрегата репозиторий пишет из поля events " <>
          "(use Core.Struct, events: Core.EventFixture.Event)"

      assert_raise CompileError, message, fn ->
        compile!(NoEvents, entity: NoEventsEntity)
      end
    end

    test "entity: — семейство events: не равно семейству кодека — CompileError" do
      message =
        "Repo.Pg.StateStored: entity: Core.Repo.Pg.StateStoredTest.ForeignEventsEntity: events: " <>
          "семейство Core.EsFixture.Account.Event в use Core.Struct не равно семейству кодека Core.EventFixture.Event"

      assert_raise CompileError, message, fn ->
        compile!(ForeignEvents, entity: ForeignEventsEntity)
      end
    end

    test "событие outbox сверяется с семейством кодека" do
      message = ~r/outbox: событие .*Account\.Event .* не равно семейству кодека .*EventFixture\.Event$/

      assert_raise CompileError, message, fn ->
        compile!(OtherOutboxEvent, outbox: AccountOutbox)
      end
    end

    test "требует clause :version_mismatch в errors" do
      assert_raise CompileError,
                   ~r/Repo\.Pg\.StateStored: errors: отсутствует clause для :version_mismatch/,
                   fn ->
                     compile!(NoVersionMismatch, errors: NoVersionErrors)
                   end
    end

    test "errors: без domain/3 — CompileError до вложенного Repo.Pg" do
      message = ~r/^Repo\.Pg\.StateStored: errors: модуль .*SoloChild должен экспортировать domain\/3$/

      assert_raise CompileError, message, fn -> compile!(NoDomainErrors, errors: SoloChild) end
    end

    test "требует behaviour с insert/update/save" do
      message = ~r/^Repo\.Pg\.StateStored: behaviour: .*ReadOnlyBehaviour должен объявлять \[:insert, :update, :save\]$/

      assert_raise CompileError, message, fn -> compile!(ReadOnly, behaviour: ReadOnlyBehaviour) end
    end

    test "валидирует описание дочерней таблицы" do
      assert_raise CompileError, ~r/children: fk: ожидается атом/, fn ->
        compile!(BadFk, children: [[schema: Child, fk: "entity_id"]])
      end

      assert_raise CompileError,
                   ~r/children: schema: модуль .* должен экспортировать to_models\/1/,
                   fn ->
                     compile!(BadChildSchema, children: [[schema: Entity, fk: :entity_id]])
                   end
    end

    test "отклоняет неизвестную опцию внутри children" do
      assert_raise CompileError, ~r/children: неизвестные опции: \[:keys\]/, fn ->
        compile!(BadChildOpt, children: [[schema: Child, fk: :entity_id, keys: [:code]]])
      end
    end

    test "требует, чтобы fk был колонкой схемы" do
      assert_raise CompileError, ~r/children: fk: колонки :owner_id нет в/, fn ->
        compile!(UnknownFk, children: [[schema: Child, fk: :owner_id]])
      end
    end

    test "без ключа помимо fk требует key:" do
      assert_raise CompileError, ~r/нет первичного ключа помимо :entity_id — задайте key:/, fn ->
        compile!(NoChildKey, children: [[schema: SoloChild, fk: :entity_id]])
      end
    end

    test "отклоняет key: с несуществующей колонкой" do
      assert_raise CompileError, ~r/children: key: колонок \[:missing\] нет в/, fn ->
        compile!(BadChildKey, children: [[schema: Child, fk: :entity_id, key: ~w(missing)a]])
      end
    end

    test "отклоняет key: с fk внутри" do
      assert_raise CompileError, ~r/children: key: :entity_id — это fk/, fn ->
        compile!(FkInChildKey,
          children: [[schema: Child, fk: :entity_id, key: ~w(entity_id code)a]]
        )
      end
    end

    test "проверяет коды constraint_errors дочерней таблицы" do
      children = [[schema: Child, fk: :entity_id, constraint_errors: [some_fkey: :nope]]]

      assert_raise CompileError, ~r/отсутствует clause для :nope в .*StrictErrors/, fn ->
        compile!(BadChildErrorCode, children: children, errors: StrictErrors)
      end
    end

    test "outbox: :none — модуль публикации не требуется" do
      assert {{:module, module, _binary, _}, []} = compile!(NoneOutbox, outbox: :none)
      assert Core.Helper.Module.exports?(module, :insert, 3)
    end

    test "отклоняет нелитеральные opts" do
      assert_raise CompileError,
                   ~r/^Repo\.Pg\.StateStored: ожидается литеральный keyword, получено Keyword\.new\(\)$/,
                   fn ->
                     Code.eval_quoted(
                       quote do
                         defmodule Core.Repo.Pg.StateStoredTest.DynamicOpts do
                           use Core.Repo.Pg.StateStored, Keyword.new()
                         end
                       end
                     )
                   end
    end
  end

  describe "запись" do
    test "insert: строка, дочерние строки, события потока и outbox; события агрегата очищены" do
      id = AggID.new()
      created = event(EventFixture.created(), id, 1)

      assert {:ok, written} = @repo.insert(entity(id, 1, [created]), Context.new())

      assert Es.Events.empty?(written.events)
      assert {:ok, ^written} = @repo.get(id, :current, Context.new())
      assert wires(Es.Store.Test.events!(@codec, id)) == wires([created])
      assert outbox_names(id) == [@codec.type(created)]
    end

    test "outbox: :none: события потока записаны, записей outbox нет" do
      id = AggID.new()
      created = event(EventFixture.created(), id, 1)
      repo = StateStoredFixture.Repo.Pg.Unpublished

      assert {:ok, _written} = repo.insert(entity(id, 1, [created]), Context.new())

      assert wires(Es.Store.Test.events!(@codec, id)) == wires([created])
      assert outbox_names(id) == []
    end

    test "save идёт через переопределённые только insert/update: строка, дети, события и outbox" do
      id = AggID.new()
      created = event(EventFixture.created(), id, 1)
      renamed = event(EventFixture.created("Переименован"), id, 2)

      assert {:ok, written} = OverridingRepo.Pg.save(entity(id, 1, [created]), Context.new())
      assert_received :insert_via_override
      refute_received :update_via_override
      assert Es.Events.empty?(written.events)
      assert {:ok, ^written} = OverridingRepo.Pg.get(id, :current, Context.new())

      assert {:ok, _} = OverridingRepo.Pg.save(%{entity(id, 2, [renamed]) | name: "Переименован"}, Context.new())
      assert_received :update_via_override
      assert {:ok, %Entity{name: "Переименован"}} = OverridingRepo.Pg.get(id, :current, Context.new())
      assert wires(Es.Store.Test.events!(@codec, id)) == wires([created, renamed])
      assert outbox_names(id) == [@codec.type(created), @codec.type(renamed)]
    end

    test "save без ручного переопределения: эталон в Repo.Sc после commit, возврат входного агрегата" do
      id = AggID.new()
      context = Repo.Sc.init(Context.new())
      created = event(EventFixture.created(), id, 1)
      renamed = event(EventFixture.created("Переименован"), id, 2)

      inserted = entity(id, 1, [created])
      assert {:ok, %Entity{events: events} = written} = @repo.save(inserted, context)
      assert Es.Events.empty?(events)
      assert Repo.Sc.find(context, Entity, id) == written

      updated = entity(id, 2, [renamed])
      assert {:ok, %Entity{events: events} = written} = @repo.save(updated, context)
      assert Es.Events.empty?(events)
      assert Repo.Sc.find(context, Entity, id) == written
      assert wires(Es.Store.Test.events!(@codec, id)) == wires([created, renamed])
    end

    test "поток не с 1 и с разрывами: агрегат создан без события, мутация без события" do
      id = AggID.new()
      renamed = event(EventFixture.created("Переименован"), id, 2)
      closed = event(EventFixture.closed(), id, 4)

      assert {:ok, _} = @repo.insert(entity(id, 1, []), Context.new())
      assert {:ok, _} = @repo.update(entity(id, 2, [renamed]), Context.new())
      assert {:ok, _} = @repo.update(%{entity(id, 3, []) | name: "Без события"}, Context.new())
      assert {:ok, _} = @repo.save(entity(id, 4, [closed]), Context.new())

      assert wires(Es.Store.Test.events!(@codec, id)) == wires([renamed, closed])
    end

    test "мутация без события при эталоне — ArgumentError" do
      id = AggID.new()
      context = Repo.Sc.init(Context.new())
      created = event(EventFixture.created(), id, 1)

      assert {:ok, written} = @repo.insert(entity(id, 1, [created]), context)

      assert_raise ArgumentError, ~r/состояние изменено без события/, fn ->
        @repo.update(%{written | name: "Без события"}, context)
      end
    end

    test "занятая версия потока — :version_mismatch write-репозитория; запись откатывается" do
      id = AggID.new()
      first = event(EventFixture.created(), id, 2)
      stale = %{entity(id, 2, [event(EventFixture.closed(), id, 2)]) | name: "Устаревшее"}

      assert {:ok, _} = @repo.insert(entity(id, 1, []), Context.new())
      assert {:ok, _} = @repo.update(entity(id, 2, [first]), Context.new())

      assert {:error, %Error{module: StateStoredFixture.Repo, code: :version_mismatch} = error} =
               @repo.update(stale, Context.new())

      assert error.detail == %{aggregate_id: dump(id), expected: 2, actual: 2, source: :storage}
      assert {:ok, %Entity{name: "Приёмка"}} = @repo.get(id, :current, Context.new())
      assert wires(Es.Store.Test.events!(@codec, id)) == wires([first])
      assert outbox_names(id) == [@codec.type(first)]
    end
  end

  describe "page_stream/4" do
    test "страница потока по возрастанию версии; total — весь поток" do
      id = AggID.new()
      created = event(EventFixture.created(), id, 2)
      closed = event(EventFixture.closed(), id, 4)

      assert {:ok, _} = @repo.insert(entity(id, 1, []), Context.new())
      assert {:ok, _} = @repo.update(entity(id, 2, [created]), Context.new())
      assert {:ok, _} = @repo.update(%{entity(id, 3, []) | name: "Без события"}, Context.new())
      assert {:ok, _} = @repo.update(entity(id, 4, [closed]), Context.new())

      assert {:ok, %Pagination.Result{items: items, total: 2}} = page(id, 1, 1)

      assert wires(items) == wires([closed])
    end

    test "агрегат без событий — страница с total: 0" do
      id = AggID.new()

      assert {:ok, _} = @repo.insert(entity(id, 1, []), Context.new())

      assert {:ok, %Pagination.Result{items: [], total: 0}} = page(id, 10, 0)
    end
  end

  describe "ПДн в строке" do
    test "живое ПДн открыто в строке, уничтоженное — {\"$pd\": null}, чтение без хранилища ключей" do
      id = AggID.new()
      profile = %Profile{phone: Contact.new!(@contact)}

      assert {:ok, written} = @repo.insert(%{entity(id, 1, []) | holder: profile}, Context.new())
      assert written.holder == profile
      assert stored_holder(id) == %{"phone" => @contact}

      attach_personal_calls()
      assert {:ok, %Entity{holder: ^profile}} = @repo.get(id, :current, Context.new())
      refute_received {:personal_call, _op}

      destroyed = %{entity(id, 2, []) | holder: %Profile{phone: %Destroyed{}}}
      assert {:ok, %Entity{holder: %Profile{phone: %Destroyed{}}}} = @repo.update(destroyed, Context.new())
      assert stored_holder(id) == %{"phone" => %{"$pd" => nil}}

      assert {:ok, %Entity{holder: %Profile{phone: %Destroyed{}}}} = @repo.get(id, :current, Context.new())
      refute_received {:personal_call, _op}

      container = %{entity(id, 3, []) | holder: %Destroyed{}}
      assert {:ok, %Entity{holder: %Destroyed{}}} = @repo.update(container, Context.new())
      assert stored_holder(id) == %{"$pd" => nil}
      assert {:ok, %Entity{holder: %Destroyed{}}} = @repo.get(id, :current, Context.new())
      refute_received {:personal_call, _op}
    end

    test "новый event с уничтоженным ПДн — запись отказывает, строка не пишется" do
      id = AggID.new()
      event = EventFixture.contact_set(PersonID.new(), @contact, "Заметка")
      payload = %{event.payload | contact: %Destroyed{}}
      state = entity(id, 1, [%{event | payload: payload}])

      assert_raise ArgumentError, ~r/уничтоженное ПДн-значение не записывается в новое событие/, fn ->
        @repo.insert(state, Context.new())
      end

      assert {:error, %Error{code: :not_found}} = @repo.get(id, :current, Context.new())
    end
  end

  # `prelude` стоит в теле перед `use`: тело раскрывается целиком до вычисления, поэтому ошибка
  # раскрытия приходит раньше, чем `raise` в `prelude`.
  defp compile!(name, overrides, prelude \\ nil) do
    opts =
      base_opts()
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          unquote(prelude)
          use Core.Repo.Pg.StateStored, unquote(opts)
        end
      end
    )
  end

  defp base_opts do
    [
      behaviour: StateStoredFixture.Repo,
      schema: StateStoredFixture.Schema,
      to_entity: quote(do: &Function.identity/1),
      to_model: quote(do: &Function.identity/1),
      id: AggID,
      entity: Entity,
      errors: EventFixture.Errors,
      event_codec: @codec,
      outbox: StateStoredFixture.Outbox
    ]
  end

  defp entity(id, version, events) do
    %Entity{
      id: id,
      version: Version.new!(version),
      name: "Приёмка",
      children: %{"first" => "Первая"},
      events: Es.Events.new(events)
    }
  end

  defp event(event, id, version), do: EventFixture.in_stream(event, id, version)

  defp page(id, limit, offset),
    do: @repo.page_stream(id, Pagination.Limit.new!(limit), Pagination.Offset.new!(offset), Context.new())

  defp outbox_names(id) do
    key = dump(id)

    TestRepo.all(from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key, select: r.name))
  end

  # Операцию записи ставит репозиторий (`Core.Es.Operation`), её проверяет `Core.Es.OperationTest`.
  defp wires(events), do: Enum.map(events, &dump(%{&1 | operation_id: nil}))

  defp stored_holder(id) do
    TestRepo.one!(from(e in StateStoredFixture.Schema, where: e.id == ^dump(id), select: e.holder))
  end

  defp attach_personal_calls do
    test = self()
    handler = "state-stored-personal-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        Telemetry.event([:es, :personal, :call]),
        fn _event, _measurements, metadata, _config -> send(test, {:personal_call, metadata.op}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp dump(value), do: Config.codec().dump(value)
end
