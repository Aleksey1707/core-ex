defmodule Core.MacroConfigTest do
  @moduledoc """
  Компиляция макросов не имеет права требовать конфигурацию потребителя.

  Библиотека собирается как зависимость — раньше конфигурации приложения и всегда раньше
  `runtime.exs`, поэтому `codec:` / `repo:` без явной опции резолвятся в рантайме
  (`10-architecture.md`). Тест снимает ключи `:core` и компилирует модули без них.
  """

  use ExUnit.Case, async: false

  alias Core.CodecFixture
  alias Core.Error
  alias Core.EventFixture
  alias Core.Repo

  require Error

  defmodule Errors do
    @moduledoc false

    def domain(module, code, detail) do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  defmodule Entity do
    @moduledoc false

    defstruct ~w(id events)a

    @type t :: %__MODULE__{}
  end

  defmodule Behaviour do
    @moduledoc false

    use Core.Repo, only: [:get, :insert, :update, :save, :exists?]
  end

  defmodule EventRepo do
    @moduledoc false

    use Core.Es.Event.Repo,
      event: Core.EventFixture.Event,
      aggregate_id: Core.EventFixture.AggID
  end

  defmodule EventRepoImpl do
    @moduledoc false

    def append(_events, _context, _opts \\ []), do: :ok
  end

  defmodule Outbox do
    @moduledoc false

    def from_events(events) when is_list(events), do: {:ok, events}
  end

  setup do
    codec = Application.fetch_env!(:core, :codec)
    dao = Application.fetch_env!(:core, :dao)

    # DI доменного репозитория событий — единственный ключ, который `Repo.Pg.Es` читает
    # на компиляции (`Application.compile_env!`, документированное исключение).
    Application.put_env(:core, EventRepo, EventRepoImpl)

    on_exit(fn ->
      Application.put_env(:core, :codec, codec)
      Application.put_env(:core, :dao, dao)
      Application.delete_env(:core, EventRepo)
    end)

    Application.delete_env(:core, :codec)
    Application.delete_env(:core, :dao)

    %{codec: codec, dao: dao}
  end

  describe "компиляция без конфигурации потребителя" do
    test "Es.Outbox — без codec" do
      assert_compiles(EsOutbox, """
        use Core.Es.Outbox, topic: "fakes", event: Core.EventFixture.Event
      """)
    end

    test "Es.Event.Repo.Pg и его Schema — без codec и dao" do
      assert_compiles(EsEventSchema, """
        use Core.Es.Event.Repo.Pg.Schema,
          table: "fake_events",
          event: Core.EventFixture.Event,
          by_schema: Core.EventFixture.BySchema,
          payload_type: Core.TestTypes.JSON
      """)

      assert_compiles(EsEventRepoPg, """
        use Core.Es.Event.Repo.Pg,
          behaviour: Core.MacroConfigTest.EventRepo,
          schema: Core.MacroConfigTest.EsEventSchema,
          aggregate_id: Core.EventFixture.AggID,
          errors: Core.EventFixture.Errors
      """)
    end

    test "Repo.Pg — без dao" do
      assert_compiles(RepoPg, """
        use Core.Repo.Pg,
          behaviour: Core.MacroConfigTest.Behaviour,
          schema: Core.MacroConfigTest.Entity,
          to_entity: &Function.identity/1,
          to_model: &Function.identity/1,
          entity: Core.MacroConfigTest.Entity,
          errors: Core.MacroConfigTest.Errors
      """)
    end

    test "Repo.Pg.Schema — без codec" do
      assert_compiles(RepoPgSchema, """
        use Ecto.Schema

        @primary_key {:id, :binary_id, autogenerate: false}

        schema "fake_rows" do
          field :name, :string
        end

        use Core.Repo.Pg.Schema,
          entity: Core.MacroConfigTest.Entity,
          id: Core.EventFixture.AggID

        def to_entity(%__MODULE__{} = row), do: {:ok, %Core.MacroConfigTest.Entity{id: row.id}}

        def to_model(%Core.MacroConfigTest.Entity{} = entity), do: {:ok, %{id: entity.id}}
      """)
    end

    test "Repo.Pg.Es — без dao" do
      assert_compiles(RepoPgEs, """
        use Core.Repo.Pg.Es,
          behaviour: Core.MacroConfigTest.Behaviour,
          schema: Core.MacroConfigTest.Entity,
          to_entity: &Function.identity/1,
          to_model: &Function.identity/1,
          entity: Core.MacroConfigTest.Entity,
          errors: Core.MacroConfigTest.Errors,
          event_repo: Core.MacroConfigTest.EventRepo,
          outbox: Core.MacroConfigTest.Outbox
      """)
    end
  end

  describe "резолв в момент вызова" do
    test "Repo.Pg.dao/1 читает конфиг на каждом вызове", ctx do
      Application.put_env(:core, :dao, ctx.dao)
      assert Repo.Pg.dao(%{dao: nil}) == ctx.dao

      Application.put_env(:core, :dao, Core.OtherRepo)
      assert Repo.Pg.dao(%{dao: nil}) == Core.OtherRepo

      assert Repo.Pg.dao(%{dao: ctx.dao}) == ctx.dao
    end

    test "Es.Outbox дампит событие текущим фасадом" do
      assert_compiles(LateCodec, """
        use Core.Es.Outbox, topic: "fakes", event: Core.EventFixture.Event
      """)

      module = Module.concat(__MODULE__, LateCodec)
      event = EventFixture.created()

      Application.put_env(:core, :codec, CodecFixture.Internal)
      assert {:ok, internal} = module.from_event(event)
      assert %DateTime{} = internal.payload["at"]

      Application.put_env(:core, :codec, CodecFixture.External)
      assert {:ok, external} = module.from_event(event)
      assert is_binary(external.payload["at"])
    end
  end

  # ---

  defp assert_compiles(name, body) do
    module = Module.concat(__MODULE__, name)

    Code.eval_string("""
    defmodule #{inspect(module)} do
      @moduledoc false

      #{body}
    end
    """)

    assert Code.ensure_loaded?(module)
  end
end
