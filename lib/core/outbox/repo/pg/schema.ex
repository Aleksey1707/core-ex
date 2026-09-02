defmodule Core.Outbox.Repo.Pg.Schema do
  @moduledoc """
  Ecto-схема outbox и маппинг в доменную запись.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Core.Config
  alias Core.Error
  alias Core.Outbox
  alias Core.Outbox.Record

  defmodule JsonList do
    @moduledoc """
    Ecto-тип для jsonb-массива (история ошибок записи outbox).

    Штатный `:map` не принимает список, а `{:array, :map}` в jsonb-колонке даёт
    другой wire-формат.
    """
    use Ecto.Type

    @doc false
    @impl true
    def type, do: :map

    @doc false
    @impl true
    def cast(value) when is_list(value), do: {:ok, value}
    def cast(_), do: :error

    @doc false
    @impl true
    def load(value) when is_list(value), do: {:ok, value}
    def load(nil), do: {:ok, []}
    def load(_), do: :error

    @doc false
    @impl true
    def dump(value) when is_list(value), do: {:ok, value}
    def dump(_), do: :error

    @doc false
    @impl true
    def equal?(a, b), do: a == b
  end

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "outbox" do
    field :topic, :string
    field :key, :string
    field :name, :string
    field :payload, :map, default: %{}
    field :status, Ecto.Enum, values: Outbox.Status.values()
    field :attempts, :integer, default: 0
    field :locked_until, :utc_datetime
    field :lease_id, :binary_id
    field :errors, JsonList, default: []
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    field :headers, :map
  end

  use Core.Repo.Pg.Schema,
    entity: Record,
    id: Outbox.ID

  @required ~w(id topic key name payload status attempts errors created_at)a
  @optional ~w(locked_until lease_id updated_at published_at headers)a

  @doc "Changeset для insert/update."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()

  def changeset(%__MODULE__{} = schema, attrs) when is_map(attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc "Преобразовать строку БД в доменную запись."
  @spec to_entity(t()) :: {:ok, Record.t()} | {:error, Error.t()}

  def to_entity(%__MODULE__{} = row) do
    Config.codec().load(Record, %{
      id: row.id,
      topic: row.topic,
      key: row.key,
      name: row.name,
      payload: row.payload,
      status: row.status,
      attempts: row.attempts,
      locked_until: row.locked_until,
      lease_id: row.lease_id,
      published_at: row.published_at,
      errors: row.errors || [],
      created_at: row.created_at,
      updated_at: row.updated_at,
      headers: row.headers
    })
  end

  @doc "Распаковать доменную запись в map для changeset/insert."
  @spec to_model(Record.t()) :: {:ok, map()} | {:error, Error.t()}

  def to_model(%Record{} = record) do
    dumped = Config.codec().dump(record)

    {:ok,
     %{
       id: dumped.id,
       topic: dumped.topic,
       key: dumped.key,
       name: dumped.name,
       payload: dumped.payload,
       status: dumped.status,
       attempts: dumped.attempts,
       locked_until: dumped.locked_until,
       lease_id: dumped.lease_id,
       errors: Enum.map(dumped.errors, &error_codec_attrs_to_row/1),
       created_at: dumped.created_at,
       updated_at: dumped.updated_at,
       published_at: dumped.published_at,
       headers: dumped.headers
     }}
  end

  # ---

  defp error_codec_attrs_to_row(%{attempt: attempt, message: message}) do
    %{"attempt" => attempt, "message" => message}
  end
end
