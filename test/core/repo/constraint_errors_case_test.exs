defmodule Core.Repo.ConstraintErrorsCaseTest do
  use Core.DataCase, async: true

  alias Core.ConstraintErrorsFixture
  alias Core.EventFixture
  alias Core.Repo.ConstraintErrorsCase
  alias Core.StateStoredFixture

  @write ConstraintErrorsFixture.Repo.Pg
  @save ConstraintErrorsFixture.SaveRepo.Pg
  @read ConstraintErrorsFixture.ReadRepo.Pg

  defmodule MisnamedSchema do
    @moduledoc false

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fixture_constrained" do
      field :name, :string
    end

    def changeset(%__MODULE__{} = row, attrs) do
      row
      |> cast(attrs, ~w(name)a)
      |> unique_constraint(:name, name: :fixture_constrained_title_index)
    end
  end

  # Маппинг по полю, которого нет в changeset/2; FK и unique из changeset/2 без маппинга.
  defmodule Mismapped do
    @moduledoc false

    use Core.Repo.Pg,
      behaviour: ConstraintErrorsFixture.Repo,
      schema: ConstraintErrorsFixture.Schema,
      to_entity: &Function.identity/1,
      to_model: &Function.identity/1,
      errors: ConstraintErrorsFixture.Errors,
      constraint_errors: [
        unique: [title: :already_exists],
        check: [version: :invalid_version]
      ]
  end

  # Запись только через save/3: маппинг по полю, которого нет в changeset/2.
  defmodule MismappedSave do
    @moduledoc false

    use Core.Repo.Pg,
      behaviour: ConstraintErrorsFixture.SaveRepo,
      schema: ConstraintErrorsFixture.Schema,
      to_entity: &Function.identity/1,
      to_model: &Function.identity/1,
      errors: ConstraintErrorsFixture.Errors,
      constraint_errors: [
        unique: [title: :already_exists],
        check: [version: :invalid_version]
      ]
  end

  defmodule Misnamed do
    @moduledoc false

    use Core.Repo.Pg,
      behaviour: ConstraintErrorsFixture.Repo,
      schema: MisnamedSchema,
      to_entity: &Function.identity/1,
      to_model: &Function.identity/1,
      errors: ConstraintErrorsFixture.Errors,
      constraint_errors: [unique: [name: :already_exists]]
  end

  # Дочерняя таблица: маппинг по имени, которого нет у таблицы, а FK на справочник без маппинга.
  defmodule MismappedChildren do
    @moduledoc false

    use Core.Repo.Pg.StateStored,
      behaviour: ConstraintErrorsFixture.Repo,
      schema: ConstraintErrorsFixture.Schema,
      to_entity: &Function.identity/1,
      to_model: &Function.identity/1,
      id: EventFixture.AggID,
      entity: StateStoredFixture.Entity,
      errors: ConstraintErrorsFixture.Errors,
      constraint_errors: [
        unique: [name: :already_exists],
        foreign_key: [ref_id: :unknown_ref],
        check: [version: :invalid_version]
      ],
      event_codec: EventFixture.Event.Codec,
      outbox: StateStoredFixture.Outbox,
      children: [
        [
          schema: ConstraintErrorsFixture.Child,
          fk: :entity_id,
          constraint_errors: [fixture_constrained_children_other_fkey: :unknown_ref]
        ]
      ]
  end

  defmodule MappedReadRepo do
    @moduledoc false

    use Core.Repo.Pg,
      behaviour: ConstraintErrorsFixture.ReadRepo,
      schema: ConstraintErrorsFixture.ReadSchema,
      to_entity: &Function.identity/1,
      errors: ConstraintErrorsFixture.Errors,
      constraint_errors: [unique: [name: :already_exists]]
  end

  describe "repos!/1" do
    test "модули приложения с __constraint_errors__/0" do
      repos = ConstraintErrorsCase.repos!(:core)

      assert @write in repos
      assert @read in repos
      assert StateStoredFixture.Repo.Pg in repos
      refute Mismapped in repos
    end

    test "приложение не загружено — ArgumentError" do
      assert_raise ArgumentError, ~r/приложение :unknown_app не загружено/, fn ->
        ConstraintErrorsCase.repos!(:unknown_app)
      end
    end

    test "в приложении нет репозиториев — ArgumentError" do
      assert_raise ArgumentError, ~r/в приложении :logger нет репозиториев/, fn ->
        ConstraintErrorsCase.repos!(:logger)
      end
    end
  end

  describe "check_mapping_declared/1" do
    test "ключ маппинга, которого нет в changeset/2, — репозиторий и ключ" do
      assert {:error, %{undeclared: [{Mismapped, {:unique, :title}}]}} =
               ConstraintErrorsCase.check_mapping_declared([@write, @read, Mismapped])
    end

    test "репозиторий с записью только через save/3 — write-путь" do
      assert {:error, %{undeclared: [{MismappedSave, {:unique, :title}}]}} =
               ConstraintErrorsCase.check_mapping_declared([@save, @read, MismappedSave])
    end
  end

  describe "check_constraints_mapped/1" do
    test "ограничение changeset/2 без маппинга — репозиторий и {error_type, поле}" do
      assert {:error, %{unmapped: [{Mismapped, {:foreign, :ref_id}}, {Mismapped, {:unique, :name}}]}} =
               ConstraintErrorsCase.check_constraints_mapped([@write, @read, Mismapped])
    end
  end

  describe "check_constraint_names/2" do
    test "имя из changeset/2 или children:, которого нет у таблицы, — репозиторий, таблица и имя" do
      missing = [
        {MismappedChildren, "fixture_constrained_children", "fixture_constrained_children_other_fkey"},
        {Misnamed, "fixture_constrained", "fixture_constrained_title_index"}
      ]

      assert {:error, %{missing: ^missing}} =
               ConstraintErrorsCase.check_constraint_names([@write, Misnamed, MismappedChildren], TestRepo)
    end
  end

  describe "check_children_foreign_keys/2" do
    test "FK дочерней таблицы без маппинга, кроме FK по колонке fk:, — репозиторий, таблица и имя" do
      unmapped = [
        {MismappedChildren, "fixture_constrained_children", "fixture_constrained_children_ref_id_fkey"}
      ]

      assert {:error, %{unmapped_foreign_keys: ^unmapped}} =
               ConstraintErrorsCase.check_children_foreign_keys([@write, @read, MismappedChildren], TestRepo)
    end
  end

  describe "check_read_repos/1" do
    test "read-репозиторий с constraint_errors — репозиторий" do
      assert {:error, %{mapped: [MappedReadRepo]}} =
               ConstraintErrorsCase.check_read_repos([@write, @read, MappedReadRepo])
    end

    test "репозиторий с записью только через save/3 — не read" do
      assert :ok = ConstraintErrorsCase.check_read_repos([@save, MismappedSave])
    end
  end

  describe "опции" do
    test "без otp_app: — CompileError" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:otp_app\]/, fn ->
        use_case([])
      end
    end

    test "otp_app: не атом — CompileError" do
      assert_raise CompileError, ~r/otp_app: ожидается атом/, fn ->
        use_case(otp_app: "core")
      end
    end

    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/async: ожидается boolean/, fn ->
        use_case(otp_app: :core, async: :yes)
      end
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:repo\]/, fn ->
        use_case(otp_app: :core, repo: TestRepo)
      end
    end
  end

  # ---

  defp use_case(opts) do
    Code.eval_quoted(
      quote do
        defmodule Core.Repo.ConstraintErrorsCaseTest.Ratchet do
          use Core.Repo.ConstraintErrorsCase, unquote(opts)
        end
      end
    )
  end
end
