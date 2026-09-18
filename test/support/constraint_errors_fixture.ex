defmodule Core.ConstraintErrorsFixture do
  @moduledoc """
  Репозитории тестов `Core.Repo.ConstraintErrorsCase`: write-репозиторий, чьи `constraint_errors`
  сходятся с `changeset/2` и с ограничениями БД, такой же write-репозиторий с записью только через
  `save/3` (`only: ~w(get save)a`) и read-репозиторий без `constraint_errors`.

  Таблицы — миграция `priv/repo/migrations/20260917130000_create_constraint_errors_fixture.exs`.
  Агрегат, кодек событий и outbox — `Core.StateStoredFixture` и `Core.EventFixture`: case-модуль
  читает только декларации, строк репозитории не пишут.
  """

  defmodule Errors do
    @moduledoc "Каталог доменных ошибок: коды репозитория и коды маппинга ограничений."

    alias Core.Error

    require Error

    @codes ~w(not_found version_mismatch incomplete_result no_ids already_exists unknown_ref invalid_version)a

    @doc "Доменная ошибка по коду."
    @spec domain(module(), atom(), term()) :: Error.t()

    def domain(module, code, detail) when code in @codes do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  defmodule Child do
    @moduledoc "Ecto-схема дочерней строки: FK на агрегат и на справочник."

    use Ecto.Schema

    @primary_key false

    schema "fixture_constrained_children" do
      field :entity_id, :binary_id, primary_key: true
      field :code, :string, primary_key: true
      field :ref_id, :binary_id
    end

    @doc "Агрегат → дочерние строки."
    @spec to_models(struct()) :: [map()]

    def to_models(_entity), do: []
  end

  defmodule Schema do
    @moduledoc "Ecto-схема строки агрегата с unique-индексом, FK и check-ограничением."

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fixture_constrained" do
      field :name, :string
      field :version, :integer
      field :ref_id, :binary_id
    end

    @doc "Строка + атрибуты → changeset записи."
    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()

    def changeset(%__MODULE__{} = row, attrs) do
      row
      |> cast(attrs, ~w(id name version ref_id)a)
      |> unique_constraint(:name)
      |> foreign_key_constraint(:ref_id)
      |> check_constraint(:version, name: :fixture_constrained_version_positive)
    end
  end

  defmodule ReadSchema do
    @moduledoc "Ecto-схема read-репозитория: та же таблица, без `changeset/2`."

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fixture_constrained" do
      field :name, :string
      field :version, :integer
    end
  end

  defmodule Repo do
    @moduledoc "Write-behaviour агрегата."

    use Core.Repo,
      only: ~w(insert update save)a,
      entity: Core.StateStoredFixture.Entity,
      id: Core.EventFixture.AggID
  end

  defmodule Repo.Pg do
    @moduledoc "Write-репозиторий: маппинг на каждое ограничение строки и дочерней таблицы."

    alias Core.ConstraintErrorsFixture.Child
    alias Core.ConstraintErrorsFixture.Errors
    alias Core.ConstraintErrorsFixture.Schema
    alias Core.EventFixture
    alias Core.StateStoredFixture

    use Core.Repo.Pg.StateStored,
      behaviour: Core.ConstraintErrorsFixture.Repo,
      schema: Schema,
      to_entity: &Function.identity/1,
      to_model: &Function.identity/1,
      id: EventFixture.AggID,
      entity: StateStoredFixture.Entity,
      errors: Errors,
      constraint_errors: [
        unique: [name: :already_exists],
        foreign_key: [ref_id: :unknown_ref],
        check: [version: :invalid_version]
      ],
      event_codec: EventFixture.Event.Codec,
      outbox: StateStoredFixture.Outbox,
      children: [
        [
          schema: Child,
          fk: :entity_id,
          constraint_errors: [fixture_constrained_children_ref_id_fkey: :unknown_ref]
        ]
      ]
  end

  defmodule SaveRepo do
    @moduledoc "Write-behaviour агрегата с записью только через `save/3`."

    use Core.Repo,
      only: ~w(get save)a,
      entity: Core.StateStoredFixture.Entity,
      id: Core.EventFixture.AggID
  end

  defmodule SaveRepo.Pg do
    @moduledoc "Write-репозиторий без `insert` / `update`: маппинг на каждое ограничение строки."

    alias Core.ConstraintErrorsFixture.Errors
    alias Core.ConstraintErrorsFixture.Schema
    alias Core.EventFixture
    alias Core.StateStoredFixture

    use Core.Repo.Pg,
      behaviour: Core.ConstraintErrorsFixture.SaveRepo,
      schema: Schema,
      to_entity: &Function.identity/1,
      to_model: &Function.identity/1,
      id: EventFixture.AggID,
      entity: StateStoredFixture.Entity,
      errors: Errors,
      constraint_errors: [
        unique: [name: :already_exists],
        foreign_key: [ref_id: :unknown_ref],
        check: [version: :invalid_version]
      ]
  end

  defmodule ReadRepo do
    @moduledoc "Read-behaviour агрегата."

    use Core.Repo, only: :read
  end

  defmodule ReadRepo.Pg do
    @moduledoc "Read-репозиторий: `constraint_errors` не объявляет."

    alias Core.ConstraintErrorsFixture.Errors
    alias Core.ConstraintErrorsFixture.ReadSchema

    use Core.Repo.Pg,
      behaviour: Core.ConstraintErrorsFixture.ReadRepo,
      schema: ReadSchema,
      to_entity: &Function.identity/1,
      errors: Errors
  end
end
