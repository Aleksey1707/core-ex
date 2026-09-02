defmodule Core.Es.Event.RepoTest do
  use ExUnit.Case, async: true

  alias Core.Error
  require Error

  defmodule FakeId do
    @moduledoc false

    use Core.Prim.UUID,
      name: "Идентификатор",
      version: 7
  end

  defmodule FakeEvent do
    @moduledoc false

    defstruct ~w(id aggregate_id aggregate_version at by)a

    @type t :: %__MODULE__{}

    def name(%__MODULE__{}), do: "faked"
  end

  defmodule Errors do
    @moduledoc false

    def domain(module, :version_mismatch = code, detail) do
      Error.domain(module,
        code: code,
        ns: :fake,
        message: "Версия не совпадает с ожидаемой",
        detail: detail
      )
    end
  end

  defmodule NoVersionErrors do
    @moduledoc false

    def domain(module, :not_found = code, detail) do
      Error.domain(module, code: code, ns: :fake, message: "Не найдено", detail: detail)
    end
  end

  defmodule Behaviour do
    @moduledoc false

    use Core.Es.Event.Repo,
      event: Core.Es.Event.RepoTest.FakeEvent,
      aggregate_id: Core.Es.Event.RepoTest.FakeId
  end

  test "behaviour объявляет append, чтение по агрегату и счётчик" do
    assert Enum.sort(Behaviour.behaviour_info(:callbacks)) == [
             append: 2,
             append: 3,
             count_by_aggregate: 2,
             list_by_aggregate: 2,
             list_by_aggregate: 3,
             page_by_aggregate: 4
           ]
  end

  test "behaviour требует обязательные опции" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:aggregate_id\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.Event.RepoTest.MissingId do
            use Core.Es.Event.Repo, event: Core.Es.Event.RepoTest.FakeEvent
          end
        end
      )
    end
  end

  test "behaviour отклоняет неизвестную опцию" do
    assert_raise CompileError, ~r/unknown option\(s\): \[:table\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.Event.RepoTest.UnknownOpt do
            use Core.Es.Event.Repo,
              event: Core.Es.Event.RepoTest.FakeEvent,
              aggregate_id: Core.Es.Event.RepoTest.FakeId,
              table: "fakes"
          end
        end
      )
    end
  end

  test "Pg требует clause :version_mismatch в каталоге ошибок" do
    assert_raise CompileError, ~r/отсутствует clause для :version_mismatch/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.Event.RepoTest.BadErrors do
            use Core.Es.Event.Repo.Pg,
              behaviour: Core.Es.Event.RepoTest.Behaviour,
              schema: Core.Es.Event.RepoTest.FakeEvent,
              aggregate_id: Core.Es.Event.RepoTest.FakeId,
              errors: Core.Es.Event.RepoTest.NoVersionErrors
          end
        end
      )
    end
  end

  test "Schema требует у event_codec функцию load_event/8" do
    assert_raise CompileError, ~r/должен экспортировать load_event\/8/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Es.Event.RepoTest.BadCodec do
            use Core.Es.Event.Repo.Pg.Schema,
              table: "fake_events",
              event: Core.Es.Event.RepoTest.FakeEvent,
              event_codec: Core.Es.Event.RepoTest.FakeEvent,
              aggregate_id: Core.Es.Event.RepoTest.FakeId,
              by: Core.Es.Event.RepoTest.FakeId,
              by_schema: Core.EventFixture.BySchema,
              payload_type: Core.TestTypes.JSON
          end
        end
      )
    end
  end
end
