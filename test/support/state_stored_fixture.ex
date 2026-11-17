defmodule Core.StateStoredFixture do
  @moduledoc """
  State-stored агрегат тестов `Core.Repo.Pg.StateStored`: строка, дочерние строки и события
  `Core.EventFixture`.

  Таблицы — миграция `priv/repo/migrations/20260914130000_create_state_stored_fixture.exs`.
  Версию агрегата и его события ставит тест, как домен потребителя: репозиторий её только
  проверяет.
  """

  defmodule Profile do
    @moduledoc "Профиль владельца — вложенное ПДн-место `phone`."

    use Core.Struct, fields: [phone: [prim: Core.EventFixture.Contact]]
  end

  defmodule Profile.Codec do
    @moduledoc "Плагин профиля по полям."

    use Core.Codec.Plugin, types: [Core.StateStoredFixture.Profile]
  end

  defmodule Entity do
    @moduledoc """
    Агрегат: название, ПДн-профиль владельца (`holder`), дочерние строки `код => название` и
    накопленные события.

    `holder` — ПДн-место state-stored строки: живое значение лежит открытым (`update`/`delete`
    стирают его), уничтоженное — `{"$pd": null}` в jsonb-колонке. Шифрования строки нет.
    """

    alias Core.EventFixture
    alias Core.StateStoredFixture.Profile
    alias Core.Version

    use Core.Struct,
      fields: [
        id: [prim: EventFixture.AggID],
        version: [prim: Version],
        name: [type: :string],
        holder: [entity: Profile, optional: true, default: nil],
        children: [map: [key: [type: :string], value: [type: :string]]]
      ],
      events: EventFixture.Event
  end

  defmodule Child do
    @moduledoc "Ecto-схема дочерней строки агрегата."

    use Ecto.Schema

    alias Core.StateStoredFixture.Entity
    alias Core.StateStoredFixture.Schema

    @primary_key false

    schema "fixture_entity_children" do
      field :entity_id, :binary_id, primary_key: true
      field :code, :string, primary_key: true
      field :name, :string
    end

    @doc "Агрегат → все его дочерние строки."
    @spec to_models(Entity.t()) :: [map()]

    def to_models(%Entity{} = entity) do
      entity_id = Schema.dump_id(entity.id)

      Enum.map(entity.children, fn {code, name} ->
        %{entity_id: entity_id, code: code, name: name}
      end)
    end
  end

  defmodule Schema do
    @moduledoc "Ecto-схема строки агрегата."

    use Ecto.Schema

    import Ecto.Changeset
    import Ecto.Query, only: [from: 2]

    alias Core.Config
    alias Core.Es
    alias Core.Es.Personal.Destroyed
    alias Core.EventFixture.AggID
    alias Core.Result
    alias Core.StateStoredFixture.Child
    alias Core.StateStoredFixture.Entity
    alias Core.StateStoredFixture.Profile
    alias Core.Version

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fixture_entities" do
      field :name, :string
      field :version, :integer
      field :holder, :map

      has_many :children, Child, foreign_key: :entity_id
    end

    use Core.Repo.Pg.Schema,
      entity: Entity,
      id: AggID

    @doc "Запрос агрегата вместе с дочерними строками."
    @spec base_query() :: Ecto.Query.t()

    def base_query, do: from(e in __MODULE__, preload: [:children])

    @doc "Строка → агрегат."
    @spec to_entity(t()) :: Result.t(Entity.t())

    def to_entity(%__MODULE__{} = row) do
      with {:ok, id} <- Config.codec().load(AggID, row.id),
           {:ok, version} <- Version.new(row.version),
           {:ok, holder} <- load_holder(row.holder) do
        {:ok,
         %Entity{
           id: id,
           version: version,
           name: row.name,
           holder: holder,
           children: Map.new(row.children, &{&1.code, &1.name}),
           events: Es.Events.new()
         }}
      end
    end

    @doc "Агрегат → атрибуты строки."
    @spec to_model(Entity.t()) :: {:ok, map()}

    def to_model(%Entity{} = entity) do
      {:ok,
       %{
         id: dump_id(entity.id),
         name: entity.name,
         version: Version.value(entity.version),
         holder: dump_holder(entity.holder)
       }}
    end

    @doc "Строка + атрибуты → changeset записи."
    @spec changeset(t(), map()) :: Ecto.Changeset.t()

    def changeset(%__MODULE__{} = row, attrs), do: cast(row, attrs, ~w(id name version holder)a)

    # ---

    # Живое ПДн в mutable-строке остаётся открытым wire-значением сущности (плагин его полей);
    # уничтоженное — `{"$pd": null}` на каждом ПДн-месте, которое читается без хранилища ключей.
    defp dump_holder(nil), do: nil
    defp dump_holder(%Destroyed{}), do: %{"$pd" => nil}
    defp dump_holder(%Profile{phone: %Destroyed{}}), do: %{"phone" => %{"$pd" => nil}}
    defp dump_holder(%Profile{} = profile), do: Profile.Codec.dump(profile, Config.codec())

    defp load_holder(nil), do: {:ok, nil}
    defp load_holder(%{"$pd" => nil}), do: {:ok, %Destroyed{}}
    defp load_holder(wire), do: Profile.Codec.load(Profile, wire, Config.codec())
  end

  defmodule Outbox do
    @moduledoc "Маппинг событий агрегата в записи outbox."

    use Core.Es.Outbox,
      topic: "fixture",
      family: Core.EventFixture.Event
  end

  defmodule Repo do
    @moduledoc "Write-behaviour агрегата."

    use Core.Repo,
      only: ~w(get insert update save)a,
      entity: Core.StateStoredFixture.Entity,
      id: Core.EventFixture.AggID
  end

  defmodule Repo.Pg do
    @moduledoc "Write-репозиторий агрегата."

    alias Core.EventFixture
    alias Core.StateStoredFixture.Child
    alias Core.StateStoredFixture.Entity
    alias Core.StateStoredFixture.Schema

    use Core.Repo.Pg.StateStored,
      behaviour: Core.StateStoredFixture.Repo,
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
  end

  defmodule Repo.Pg.Unpublished do
    @moduledoc "Write-репозиторий агрегата без публикации наружу: `outbox: :none`."

    alias Core.EventFixture
    alias Core.StateStoredFixture.Child
    alias Core.StateStoredFixture.Entity
    alias Core.StateStoredFixture.Schema

    use Core.Repo.Pg.StateStored,
      behaviour: Core.StateStoredFixture.Repo,
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
      outbox: :none,
      children: [[schema: Child, fk: :entity_id]]
  end
end
