defmodule Core.EventFixture do
  @moduledoc """
  Заглушки для макросов event store, которым нужны модули из приложения-потребителя.

  Роль фейкового агрегата: идентификаторы, события с нагрузкой и без, каталог доменных
  ошибок и кодек событий. `Core.EventFixture.Codec` зарегистрирован в
  `Core.CodecFixture.plugins/0` — иначе фасады не смогли бы дампить события.
  """

  defmodule BySchema do
    @moduledoc "Ecto-схема автора события (`by_schema:` у `Es.Event.Repo.Pg.Schema`)."

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}

    schema "fake_users" do
      field :login, :string
    end
  end

  defmodule AggID do
    @moduledoc "Идентификатор агрегата."

    use Core.Prim.UUID,
      name: "Идентификатор агрегата",
      version: 7
  end

  defmodule ActorID do
    @moduledoc "Идентификатор автора события."

    use Core.Prim.UUID,
      name: "Идентификатор автора",
      version: 7
  end

  defmodule Name do
    @moduledoc "Название агрегата — нагрузка события."

    use Core.Prim.String,
      name: "Название",
      min_len: 1,
      max_len: 50
  end

  defmodule Event do
    @moduledoc "События фейкового агрегата: с нагрузкой (`Created`) и без неё (`Closed`)."

    defmodule Created do
      @moduledoc "Агрегат создан."

      defmodule Payload do
        @moduledoc "Нагрузка `Created`."

        alias Core.EventFixture.Name

        @enforce_keys ~w(name)a
        defstruct @enforce_keys

        @type t :: %__MODULE__{name: Name.t()}

        @doc "Собрать нагрузку."
        @spec new(Name.t()) :: t()

        def new(%Name{} = name), do: %__MODULE__{name: name}
      end

      use Core.Es.Event,
        aggregate_id: Core.EventFixture.AggID,
        by: Core.EventFixture.ActorID,
        payload: Payload
    end

    defmodule Closed do
      @moduledoc "Агрегат закрыт."

      use Core.Es.Event,
        aggregate_id: Core.EventFixture.AggID,
        by: Core.EventFixture.ActorID,
        payload: nil
    end

    @type t :: Created.t() | Closed.t()

    @doc "Wire-имя события."
    @spec name(t()) :: String.t()

    def name(event), do: Core.EventFixture.Codec.type(event)

    @doc "Множество wire-имён событий агрегата."
    @spec names() :: MapSet.t(String.t())

    def names, do: Core.EventFixture.Codec.types()
  end

  defmodule Errors do
    @moduledoc "Каталог доменных ошибок фейкового агрегата."

    alias Core.Error

    require Error

    @doc "Доменная ошибка агрегата по коду."
    @spec domain(module(), atom(), term()) :: Error.t()

    def domain(module, :version_mismatch = code, detail) do
      Error.domain(module,
        code: code,
        ns: :fake,
        message: "Версия агрегата не совпадает",
        detail: detail
      )
    end

    def domain(module, :not_found = code, detail) do
      Error.domain(module, code: code, ns: :fake, message: "Агрегат не найден", detail: detail)
    end
  end

  defmodule Codec do
    @moduledoc "Кодек событий фейкового агрегата (плагин фасадов `Core.CodecFixture.*`)."

    alias Core.Es
    alias Core.EventFixture.Event
    alias Core.EventFixture.Name

    # Тег квалифицирован именем агрегата: он виден в брокере и в event store рядом
    # с чужими, хотя модуль выбирает внутри этого кодека.
    @tag_by_mod %{Event.Created => "fixture.created", Event.Closed => "fixture.closed"}

    use Es.Event.Codec,
      event: Event,
      tags: @tag_by_mod

    @doc "Нагрузка события → wire."
    @spec dump_payload(Event.t(), module()) :: map()

    @impl true
    def dump_payload(%Event.Created{payload: payload}, codec),
      do: %{"name" => codec.dump(payload.name)}

    @doc "Wire-нагрузка → `%Payload{}`."
    @spec load_payload(module(), term(), module()) ::
            {:ok, Event.Created.Payload.t()} | {:error, Core.Error.t()}

    @impl true
    def load_payload(Event.Created, wire, codec) do
      with {:ok, name} <- codec.load(Name, field(wire, :name)) do
        {:ok, Event.Created.Payload.new(name)}
      end
    end
  end

  alias Core.Es
  alias Core.Version

  @doc "Событие с нагрузкой; поля envelope — новые значения."
  @spec created(String.t()) :: Event.Created.t()

  def created(name \\ "Приёмка") when is_binary(name) do
    Event.Created.new(
      Event.Created.Payload.new(Name.new!(name)),
      AggID.new(),
      Version.new(),
      ActorID.new(),
      Es.Event.At.now!(),
      Es.Event.ID.new()
    )
  end

  @doc "Событие без нагрузки; поля envelope — новые значения."
  @spec closed() :: Event.Closed.t()

  def closed do
    Event.Closed.new(
      AggID.new(),
      Version.new(),
      ActorID.new(),
      Es.Event.At.now!(),
      Es.Event.ID.new()
    )
  end
end
