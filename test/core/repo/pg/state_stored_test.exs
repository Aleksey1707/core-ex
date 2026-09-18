defmodule Core.Repo.Pg.StateStoredTest do
  use Core.DataCase, async: true

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.Outbox
  alias Core.Pagination
  alias Core.Repo
  alias Core.StateStoredFixture
  alias Core.StateStoredFixture.Child
  alias Core.StateStoredFixture.Entity
  alias Core.Version

  require Config
  require Error

  @codec EventFixture.Event.Codec
  @repo Config.repo!(StateStoredFixture.Repo)

  defmodule ReadOnlyBehaviour do
    @moduledoc false

    use Core.Repo, only: :read
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

  defmodule CreatedOutbox do
    @moduledoc false

    use Core.Es.Outbox,
      topic: "fixture",
      event: Core.EventFixture.Event.Created
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

    test "отклоняет неизвестную собственную опцию" do
      assert_raise CompileError,
                   ~r/Repo\.Pg\.StateStored: неизвестные опции: \[:childrens\]/,
                   fn ->
                     compile!(BadOwnOpt, childrens: [])
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

    test "событие outbox сверяется с семейством кодека" do
      message = ~r/outbox: событие .*\.Event\.Created .* не равно семейству кодека .*\.Event$/

      assert_raise CompileError, message, fn ->
        compile!(OtherOutboxEvent, outbox: CreatedOutbox)
      end
    end

    test "требует clause :version_mismatch в errors" do
      assert_raise CompileError,
                   ~r/Repo\.Pg\.StateStored: errors: отсутствует clause для :version_mismatch/,
                   fn ->
                     compile!(NoVersionMismatch, errors: NoVersionErrors)
                   end
    end

    test "требует behaviour с insert/update/save" do
      assert_raise CompileError, ~r/должен объявлять \[:insert, :update, :save\]/, fn ->
        compile!(ReadOnly, behaviour: ReadOnlyBehaviour)
      end
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

    test "отклоняет нелитеральные opts" do
      assert_raise CompileError,
                   ~r/Repo\.Pg\.StateStored: ожидается литеральный keyword opts/,
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
    test "страница потока по возрастанию версии; count — весь поток" do
      id = AggID.new()
      created = event(EventFixture.created(), id, 2)
      closed = event(EventFixture.closed(), id, 4)

      assert {:ok, _} = @repo.insert(entity(id, 1, []), Context.new())
      assert {:ok, _} = @repo.update(entity(id, 2, [created]), Context.new())
      assert {:ok, _} = @repo.update(%{entity(id, 3, []) | name: "Без события"}, Context.new())
      assert {:ok, _} = @repo.update(entity(id, 4, [closed]), Context.new())

      assert {:ok, %Pagination.Result{items: items, count: 2}} = page(id, 1, 1)

      assert wires(items) == wires([closed])
    end

    test "агрегат без событий — страница с count: 0" do
      id = AggID.new()

      assert {:ok, _} = @repo.insert(entity(id, 1, []), Context.new())

      assert {:ok, %Pagination.Result{items: [], count: 0}} = page(id, 10, 0)
    end
  end

  defp compile!(name, overrides) do
    opts =
      base_opts()
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
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

  defp wires(events), do: Enum.map(events, &dump/1)

  defp dump(value), do: Config.codec().dump(value)
end
