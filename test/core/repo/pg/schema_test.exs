defmodule Core.Repo.Pg.SchemaTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Exc
  require Error

  defmodule FakeId do
    @moduledoc false

    use Core.Prim.UUID,
      name: "Идентификатор",
      version: 7
  end

  defmodule Entity do
    @moduledoc false

    defstruct ~w(id name)a

    @type t :: %__MODULE__{}
  end

  defmodule Schema do
    @moduledoc false

    use Ecto.Schema

    alias Core.Error
    alias Core.Repo
    alias Core.Repo.Pg.SchemaTest.Entity
    alias Core.Repo.Pg.SchemaTest.FakeId
    require Error

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fakes" do
      field :name, :string
    end

    use Repo.Pg.Schema,
      entity: Entity,
      id: FakeId

    @doc false
    @spec to_entity(t()) :: {:ok, Entity.t()} | {:error, Error.t()}

    def to_entity(%__MODULE__{name: nil} = row), do: {:error, broken(row)}
    def to_entity(%__MODULE__{} = row), do: {:ok, %Entity{id: row.id, name: row.name}}

    @doc false
    @spec to_model(Entity.t()) :: {:ok, map()} | {:error, Error.t()}

    def to_model(%Entity{name: nil} = entity), do: {:error, broken(entity)}
    def to_model(%Entity{} = entity), do: {:ok, %{id: entity.id, name: entity.name}}

    defp broken(detail) do
      Error.domain(__MODULE__, code: :broken, ns: :fake, message: "Сломано", detail: detail)
    end
  end

  defmodule View do
    @moduledoc false

    defstruct ~w(id name)a

    @type t :: %__MODULE__{id: String.t(), name: String.t()}
  end

  defmodule ReadSchema do
    @moduledoc false

    use Ecto.Schema

    alias Core.Repo
    alias Core.Repo.Pg.SchemaTest.FakeId
    alias Core.Repo.Pg.SchemaTest.View

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fakes" do
      field :name, :string
    end

    use Repo.Pg.Schema,
      view: View,
      id: FakeId

    @doc false
    @spec to_view(t()) :: View.t()

    def to_view(%__MODULE__{} = row), do: %View{id: row.id, name: row.name}
  end

  test "bang-обёртки разворачивают успешный результат" do
    id = FakeId.new()
    row = %Schema{id: FakeId.value(id), name: "X"}

    assert %Entity{name: "X"} = Schema.to_entity!(row)
    assert %{name: "X"} = Schema.to_model!(%Entity{id: FakeId.value(id), name: "X"})
  end

  test "bang-обёртки поднимают Exc на доменной ошибке" do
    assert_raise Exc, ~r/Сломано/, fn -> Schema.to_entity!(%Schema{id: "x", name: nil}) end
    assert_raise Exc, ~r/Сломано/, fn -> Schema.to_model!(%Entity{id: "x", name: nil}) end
  end

  test "dump_id сериализует Prim через фасад" do
    id = FakeId.new()

    assert Schema.dump_id(id) == Core.CodecFixture.Internal.dump(id)
  end

  test "требует обязательные опции" do
    assert_raise CompileError, ~r/Repo\.Pg\.Schema: missing required option\(s\): \[:id\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.Pg.SchemaTest.MissingId do
            defstruct []

            use Core.Repo.Pg.Schema, entity: Core.Repo.Pg.SchemaTest.Entity
          end
        end
      )
    end
  end

  test "режим view генерирует только type и dump_id" do
    id = FakeId.new()

    assert %View{id: "x", name: "X"} = ReadSchema.to_view(%ReadSchema{id: "x", name: "X"})
    assert ReadSchema.dump_id(id) == Core.CodecFixture.Internal.dump(id)

    refute function_exported?(ReadSchema, :to_entity!, 1)
    refute function_exported?(ReadSchema, :to_model!, 1)
  end

  test "режим view требует to_view/1" do
    assert_raise CompileError, ~r/должен объявить to_view\/1/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.Pg.SchemaTest.NoToView do
            defstruct ~w(id)a

            use Core.Repo.Pg.Schema,
              view: Core.Repo.Pg.SchemaTest.View,
              id: Core.Repo.Pg.SchemaTest.FakeId
          end
        end
      )
    end
  end

  test "entity и view взаимоисключающие" do
    assert_raise CompileError, ~r/взаимоисключающие/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.Pg.SchemaTest.BothModes do
            defstruct ~w(id)a

            use Core.Repo.Pg.Schema,
              entity: Core.Repo.Pg.SchemaTest.Entity,
              view: Core.Repo.Pg.SchemaTest.View,
              id: Core.Repo.Pg.SchemaTest.FakeId
          end
        end
      )
    end
  end

  test "требует entity или view" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:entity\] или \[:view\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.Pg.SchemaTest.NoMode do
            defstruct ~w(id)a

            use Core.Repo.Pg.Schema, id: Core.Repo.Pg.SchemaTest.FakeId
          end
        end
      )
    end
  end

  test "отклоняет неизвестную опцию" do
    assert_raise CompileError, ~r/Repo\.Pg\.Schema: unknown option\(s\): \[:table\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.Pg.SchemaTest.UnknownOpt do
            defstruct []

            use Core.Repo.Pg.Schema,
              entity: Core.Repo.Pg.SchemaTest.Entity,
              id: Core.Repo.Pg.SchemaTest.FakeId,
              table: "fakes"
          end
        end
      )
    end
  end
end
