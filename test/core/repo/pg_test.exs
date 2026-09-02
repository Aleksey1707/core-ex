defmodule Core.Repo.PgTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Error
  alias Core.Version

  require Error

  defmodule FakeSchema do
    defstruct []
  end

  defmodule FakeId do
    defstruct [:value]
  end

  defmodule OtherId do
    defstruct [:value]
  end

  defmodule Errors do
    @ns :test

    def ns, do: @ns

    def domain(module, code, detail), do: domain(module, code, detail, nil)

    def domain(module, :not_found = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Запись не найдена",
        detail: detail
      )
    end

    def domain(module, :version_mismatch = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Версия записи не совпадает с ожидаемой",
        detail: detail
      )
    end

    def domain(module, :incomplete_result = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Не удалось получить все запрошенные записи",
        detail: detail
      )
    end

    def domain(module, :no_ids = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Список идентификаторов не может быть пустым",
        detail: detail
      )
    end
  end

  defmodule IncompleteErrors do
    @ns :test

    def ns, do: @ns

    def domain(module, code, detail), do: domain(module, code, detail, nil)

    def domain(module, :not_found = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Запись не найдена",
        detail: detail
      )
    end

    def domain(module, :version_mismatch = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Версия записи не совпадает с ожидаемой",
        detail: detail
      )
    end

    def domain(module, :incomplete_result = code, detail, message) do
      Error.domain(module,
        code: code,
        ns: ns(),
        message: message || "Не удалось получить все запрошенные записи",
        detail: detail
      )
    end
  end

  def always_true(_context), do: true

  defmodule WriteSchema do
    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fake_writes" do
      field :name, :string
    end

    def changeset(schema, attrs), do: cast(schema, attrs, ~w(id name)a)
  end

  defmodule VersionedSchema do
    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fake_versioned" do
      field :name, :string
      field :version, :integer
    end

    def changeset(schema, attrs), do: cast(schema, attrs, ~w(id name version)a)
  end

  defmodule VersionedDao do
    def one(_query, _opts), do: %VersionedSchema{id: "1", name: "старое", version: 3}

    def delete_all(query, _opts) do
      send(self(), {:delete_query, query})
      {0, nil}
    end

    def update(changeset, _opts) do
      send(self(), {:update_filters, changeset.filters})
      raise Ecto.StaleEntryError, action: :update, changeset: changeset
    end
  end

  defmodule StubDao do
    def insert(changeset, _opts), do: {:ok, Ecto.Changeset.apply_changes(changeset)}

    def one(_query, _opts), do: %WriteSchema{id: "1", name: "старое"}

    def update(changeset, _opts), do: {:ok, Ecto.Changeset.apply_changes(changeset)}
  end

  defmodule SampleView do
    defstruct [:id, :name, :version]

    @type t :: %__MODULE__{id: String.t(), name: String.t(), version: pos_integer()}
  end

  def to_view(%VersionedSchema{} = row) do
    %SampleView{id: row.id, name: row.name, version: row.version}
  end

  defmodule ViewReadRepo do
    use Core.Repo,
      only: :read,
      view: Core.Repo.PgTest.SampleView
  end

  defmodule ViewReadRepoPg do
    use Core.Repo.Pg,
      behaviour: Core.Repo.PgTest.ViewReadRepo,
      repo: Core.Repo.PgTest.VersionedDao,
      schema: Core.Repo.PgTest.VersionedSchema,
      to_view: &Core.Repo.PgTest.to_view/1,
      default_filters: &Core.Repo.PgTest.always_true/1,
      errors: Core.Repo.PgTest.Errors
  end

  defp write_pg(to_entity) do
    %{
      dao: StubDao,
      module: __MODULE__,
      schema: WriteSchema,
      query: WriteSchema,
      default_filters: &__MODULE__.always_true/1,
      to_entity: to_entity,
      to_model: &Function.identity/1,
      to_id: &Function.identity/1,
      version_field: :version,
      shadow_copy?: false,
      errors: Errors,
      constraint_errors: %{}
    }
  end

  defp raising_to_entity, do: fn _row -> raise "to_entity не должен вызываться" end

  test "read-репозиторий с to_view декодирует строку в представление" do
    context = Context.new()

    assert {:ok, %SampleView{id: "1", name: "старое", version: 3}} =
             ViewReadRepoPg.get(%FakeId{value: "1"}, :current, context)

    assert {:ok, %SampleView{version: 3}} =
             ViewReadRepoPg.get(%FakeId{value: "1"}, Version.new!(3), context)

    assert {:error, %Error{code: :version_mismatch}} =
             ViewReadRepoPg.get(%FakeId{value: "1"}, Version.new!(2), context)
  end

  test "read-репозиторий с to_view не получает методов записи" do
    refute function_exported?(ViewReadRepoPg, :insert, 3)
    refute function_exported?(ViewReadRepoPg, :save, 3)
    refute function_exported?(ViewReadRepoPg, :delete, 4)
    assert function_exported?(ViewReadRepoPg, :page, 4)
  end

  test "to_model обязателен только для behaviour с записью" do
    assert_raise CompileError,
                 ~r/to_model: обязателен для behaviour с insert\/update\/save/,
                 fn ->
                   Code.eval_quoted(
                     quote do
                       defmodule Core.Repo.PgTest.NoModelBehaviour do
                         use Core.Repo, only: [:get, :save]
                       end

                       defmodule Core.Repo.PgTest.NoModel do
                         use Core.Repo.Pg,
                           behaviour: Core.Repo.PgTest.NoModelBehaviour,
                           schema: Core.Repo.PgTest.FakeSchema,
                           to_entity: &Function.identity/1,
                           default_filters: &Core.Repo.PgTest.always_true/1,
                           errors: Core.Repo.PgTest.Errors
                       end
                     end
                   )
                 end
  end

  test "to_view недопустим для behaviour с записью" do
    assert_raise CompileError, ~r/to_view: недопустим для behaviour с insert\/update\/save/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.ViewWriteBehaviour do
            use Core.Repo, only: [:get, :save]
          end

          defmodule Core.Repo.PgTest.ViewWrite do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.ViewWriteBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_view: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: Core.Repo.PgTest.Errors
          end
        end
      )
    end
  end

  test "to_entity и to_view взаимоисключающие" do
    assert_raise CompileError, ~r/to_entity\/to_view: взаимоисключающие/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.BothMappersBehaviour do
            use Core.Repo, only: :read
          end

          defmodule Core.Repo.PgTest.BothMappers do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.BothMappersBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_view: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: Core.Repo.PgTest.Errors
          end
        end
      )
    end
  end

  test "требует хотя бы один декодер строки" do
    assert_raise CompileError, ~r/нужен декодер строки/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.NoMapperBehaviour do
            use Core.Repo, only: :read
          end

          defmodule Core.Repo.PgTest.NoMapper do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.NoMapperBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: Core.Repo.PgTest.Errors
          end
        end
      )
    end
  end

  test "требует опцию behaviour" do
    assert_raise CompileError, ~r/missing required option\(s\): \[:behaviour\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.MissingBehaviour do
            use Core.Repo.Pg,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              errors: Core.Repo.PgTest.Errors
          end
        end
      )
    end
  end

  test "отклоняет недопустимый shadow_copy?" do
    assert_raise CompileError, ~r/unknown shadow_copy\?: \[:maybe\]/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.ShadowBehaviour do
            use Core.Repo, only: :read
          end

          defmodule Core.Repo.PgTest.BadShadow do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.ShadowBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              shadow_copy?: :maybe,
              errors: Core.Repo.PgTest.Errors
          end
        end
      )
    end
  end

  test "отклоняет keyword вместо модуля Errors" do
    assert_raise CompileError, ~r/ожидается модуль Errors/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.KeywordErrorsBehaviour do
            use Core.Repo, only: :read
          end

          defmodule Core.Repo.PgTest.KeywordErrors do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.KeywordErrorsBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: [
                not_found: "Запись не найдена",
                version_mismatch: "Версия записи не совпадает с ожидаемой",
                incomplete_result: "Не удалось получить все запрошенные записи",
                no_ids: "Список идентификаторов не может быть пустым"
              ]
          end
        end
      )
    end
  end

  test "требует clause для всех repo-кодов" do
    assert_raise CompileError, ~r/отсутствует clause для :no_ids/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.MissingErrorsBehaviour do
            use Core.Repo, only: :read
          end

          defmodule Core.Repo.PgTest.MissingErrors do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.MissingErrorsBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: Core.Repo.PgTest.IncompleteErrors
          end
        end
      )
    end
  end

  # foreign_key: нормализуется в :foreign — именно этот error_type Ecto кладёт в ошибку
  # changeset (Ecto.Changeset.foreign_key_constraint/3), и по нему идёт сверка.
  test "нормализует constraint_errors" do
    assert %{
             {:unique, :name} => :already_exists,
             {:foreign, :created_by_id} => :invalid_ref
           } ==
             Core.Repo.Pg.normalize_constraint_errors!(
               unique: [name: :already_exists],
               foreign_key: [created_by_id: :invalid_ref]
             )
  end

  test "отклоняет неизвестный тип constraint_errors" do
    assert_raise CompileError, ~r/неизвестный тип :weird/, fn ->
      Core.Repo.Pg.normalize_constraint_errors!(weird: [name: :already_exists])
    end
  end

  test "отклоняет дубликат поля в constraint_errors" do
    assert_raise CompileError, ~r/дубликат \{:unique, :name\}/, fn ->
      Core.Repo.Pg.normalize_constraint_errors!(unique: [name: :already_exists, name: :other])
    end
  end

  test "требует clause для кодов constraint_errors" do
    assert_raise CompileError,
                 ~r/constraint_errors: отсутствует clause для :already_exists/,
                 fn ->
                   Code.eval_quoted(
                     quote do
                       defmodule Core.Repo.PgTest.MissingConstraintBehaviour do
                         use Core.Repo, only: :read
                       end

                       defmodule Core.Repo.PgTest.MissingConstraint do
                         use Core.Repo.Pg,
                           behaviour: Core.Repo.PgTest.MissingConstraintBehaviour,
                           schema: Core.Repo.PgTest.FakeSchema,
                           to_entity: &Function.identity/1,
                           to_model: &Function.identity/1,
                           default_filters: &Core.Repo.PgTest.always_true/1,
                           errors: Core.Repo.PgTest.Errors,
                           constraint_errors: [
                             unique: [name: :already_exists]
                           ]
                       end
                     end
                   )
                 end
  end

  test "match_constraint_error находит unique по полю" do
    mapping = %{{:unique, :name} => :already_exists}

    changeset = %Ecto.Changeset{
      errors: [
        {:name,
         {"has already been taken", [constraint: :unique, constraint_name: "products_name_index"]}}
      ],
      valid?: false
    }

    assert {:ok, :already_exists, :name} ==
             Core.Repo.Pg.match_constraint_error(changeset, mapping)

    assert :error == Core.Repo.Pg.match_constraint_error(changeset, %{})
  end

  test "match_constraint_error находит foreign_key по полю" do
    mapping =
      Core.Repo.Pg.normalize_constraint_errors!(foreign_key: [delivery_id: :unknown_delivery])

    changeset = %Ecto.Changeset{
      errors: [
        {:delivery_id,
         {"does not exist",
          [constraint: :foreign, constraint_name: "acceptances_delivery_id_fkey"]}}
      ],
      valid?: false
    }

    assert {:ok, :unknown_delivery, :delivery_id} ==
             Core.Repo.Pg.match_constraint_error(changeset, mapping)
  end

  test "реализует behaviour и выводит only из callbacks" do
    {{behaviour, impl}, _} =
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.PartialBehaviour do
            use Core.Repo, only: [:get, :insert]
          end

          defmodule Core.Repo.PgTest.PartialImpl do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.PartialBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: Core.Repo.PgTest.Errors
          end

          {Core.Repo.PgTest.PartialBehaviour, Core.Repo.PgTest.PartialImpl}
        end
      )

    assert function_exported?(impl, :get, 3)
    assert function_exported?(impl, :get, 4)
    assert function_exported?(impl, :insert, 2)
    assert function_exported?(impl, :insert, 3)
    refute function_exported?(impl, :update, 2)
    refute function_exported?(impl, :update, 3)

    behaviours =
      impl.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert behaviour in behaviours
  end

  test "компилируется без опции default_filters" do
    {impl, _} =
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.DefaultFiltersBehaviour do
            use Core.Repo, only: [:count]
          end

          defmodule Core.Repo.PgTest.DefaultFiltersImpl do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.DefaultFiltersBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              errors: Core.Repo.PgTest.Errors
          end

          Core.Repo.PgTest.DefaultFiltersImpl
        end
      )

    assert function_exported?(impl, :count, 1)
    assert Core.Repo.Pg.always_true(Context.new())
  end

  test "guard по id отклоняет чужой struct" do
    {impl, _} =
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.IdBehaviour do
            use Core.Repo, only: [:get]
          end

          defmodule Core.Repo.PgTest.IdImpl do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.IdBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              id: Core.Repo.PgTest.FakeId,
              errors: Core.Repo.PgTest.Errors
          end

          Core.Repo.PgTest.IdImpl
        end
      )

    assert_raise FunctionClauseError, fn ->
      impl.get(
        %Core.Repo.PgTest.OtherId{value: 1},
        :current,
        Context.new()
      )
    end
  end

  test "без опции id любой id проходит guard" do
    {impl, _} =
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.PgTest.NoIdBehaviour do
            use Core.Repo, only: [:get]
          end

          defmodule Core.Repo.PgTest.NoIdImpl do
            use Core.Repo.Pg,
              behaviour: Core.Repo.PgTest.NoIdBehaviour,
              schema: Core.Repo.PgTest.FakeSchema,
              to_entity: &Function.identity/1,
              to_model: &Function.identity/1,
              default_filters: &Core.Repo.PgTest.always_true/1,
              errors: Core.Repo.PgTest.Errors
          end

          Core.Repo.PgTest.NoIdImpl
        end
      )

    try do
      impl.get(:any_id, :current, Context.new())
    rescue
      FunctionClauseError ->
        flunk("guard должен принимать произвольный id, если опция id не задана")

      _other ->
        :ok
    end
  end

  test "write_insert пишет строку и не декодирует её обратно в domain" do
    pg = write_pg(raising_to_entity())

    assert :ok = Core.Repo.Pg.write_insert(pg, %{id: "1", name: "новое"}, Context.new())
  end

  test "insert декодирует вставленную строку в domain" do
    pg = write_pg(&%{decoded: &1.name})

    assert {:ok, %{decoded: "новое"}} =
             Core.Repo.Pg.insert(pg, %{id: "1", name: "новое"}, Context.new())
  end

  test "write_update пишет строку и не декодирует её обратно в domain" do
    pg = write_pg(raising_to_entity())

    assert :ok = Core.Repo.Pg.write_update(pg, %{id: "1", name: "новое"}, Context.new())
  end

  test "update декодирует обновлённую строку в domain" do
    pg = write_pg(&%{decoded: &1.name})

    assert {:ok, %{decoded: "новое"}} =
             Core.Repo.Pg.update(pg, %{id: "1", name: "новое"}, Context.new())
  end

  describe "конкурентная запись" do
    test "delete с %Version{} фильтрует по версии в самом DELETE" do
      pg = versioned_pg()

      assert {:error, %Error{code: :version_mismatch}} =
               Core.Repo.Pg.delete(pg, "1", Version.new!(3), Context.new())

      assert_received {:delete_query, query}
      assert inspect(query) =~ ".version =="
    end

    test "delete с :current не добавляет предикат и отдаёт not_found" do
      pg = versioned_pg()

      assert {:error, %Error{code: :not_found}} =
               Core.Repo.Pg.delete(pg, "1", :current, Context.new())

      assert_received {:delete_query, query}
      refute inspect(query) =~ ".version =="
    end

    test "update фильтрует по прочитанной версии и мапит stale в version_mismatch" do
      pg = versioned_pg()
      entity = %{id: "1", name: "новое", version: 4}

      assert {:error, %Error{code: :version_mismatch}} =
               Core.Repo.Pg.update(pg, entity, Context.new())

      assert_received {:update_filters, %{version: 3}}
    end
  end

  # ---

  defp versioned_pg do
    %{
      dao: VersionedDao,
      module: __MODULE__,
      schema: VersionedSchema,
      query: VersionedSchema,
      default_filters: &__MODULE__.always_true/1,
      to_entity: &%{decoded: &1.name},
      to_model: &Function.identity/1,
      to_id: &Function.identity/1,
      version_field: :version,
      shadow_copy?: false,
      errors: Errors,
      constraint_errors: %{}
    }
  end
end
