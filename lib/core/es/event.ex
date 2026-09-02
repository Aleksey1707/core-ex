defmodule Core.Es.Event do
  @moduledoc """
  Базовый builder отдельного события версионированного агрегата (`use`).

  Wire-имя события задаётся в `<Aggregate>.Event.Codec`, не здесь.
  """

  import Core.Helper.String, only: [first_line: 1]

  alias Core.Helper
  alias Core.Version

  defmodule ID do
    @moduledoc """
    Идентификатор события
    """

    use Core.Prim.UUID,
      name: first_line(@moduledoc),
      version: 7
  end

  defmodule At do
    @moduledoc """
    Момент события
    """

    use Core.Prim.DateTime,
      name: first_line(@moduledoc)
  end

  @type t :: %{
          required(:__struct__) => module(),
          required(:id) => ID.t(),
          required(:payload) => term(),
          required(:aggregate_id) => term(),
          required(:aggregate_version) => Version.t(),
          required(:at) => At.t(),
          required(:by) => term()
        }

  @required_keys ~w(aggregate_id by payload)a
  @optional_keys ~w()a

  @doc "Объявить событие агрегата (`aggregate_id:` / `by:` / `payload:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Es.Event.required_keys(),
        Core.Es.Event.optional_keys(),
        "Es.Event"
      )

      alias Core.Es.Event, as: EsEvent
      alias Core.Version

      import Core.Guard, only: [is_opt: 2]

      payload_mod = Keyword.fetch!(opts, :payload)
      aggregate_id_mod = Keyword.fetch!(opts, :aggregate_id)
      by_mod = Keyword.fetch!(opts, :by)

      unless is_nil(payload_mod) or is_atom(payload_mod) do
        raise CompileError, description: "option :payload must be a module or nil"
      end

      @enforce_keys ~w(id payload aggregate_id aggregate_version at by)a
      defstruct @enforce_keys

      if is_nil(payload_mod) do
        @type t :: %__MODULE__{
                id: EsEvent.ID.t(),
                payload: nil,
                aggregate_id: unquote(aggregate_id_mod).t(),
                aggregate_version: Version.t(),
                at: EsEvent.At.t(),
                by: unquote(by_mod).t()
              }

        @doc "Создать событие без нагрузки. Опциональный `id` — для восстановления из хранилища."
        @spec new(
                unquote(aggregate_id_mod).t(),
                Version.t(),
                unquote(by_mod).t(),
                EsEvent.At.t(),
                EsEvent.ID.t() | nil
              ) :: t()

        def new(aggregate_id, aggregate_version, by, at, id \\ nil)

        def new(
              %unquote(aggregate_id_mod){} = aggregate_id,
              %Version{} = aggregate_version,
              %unquote(by_mod){} = by,
              %EsEvent.At{} = at,
              id
            )
            when is_opt(id, EsEvent.ID) do
          id = id || EsEvent.ID.new()

          %__MODULE__{
            id: id,
            payload: nil,
            aggregate_id: aggregate_id,
            aggregate_version: aggregate_version,
            at: at,
            by: by
          }
        end
      else
        @type t :: %__MODULE__{
                id: EsEvent.ID.t(),
                payload: unquote(payload_mod).t(),
                aggregate_id: unquote(aggregate_id_mod).t(),
                aggregate_version: Version.t(),
                at: EsEvent.At.t(),
                by: unquote(by_mod).t()
              }

        @doc "Создать событие. Опциональный `id` — для восстановления из хранилища."
        @spec new(
                unquote(payload_mod).t(),
                unquote(aggregate_id_mod).t(),
                Version.t(),
                unquote(by_mod).t(),
                EsEvent.At.t(),
                EsEvent.ID.t() | nil
              ) :: t()

        def new(payload, aggregate_id, aggregate_version, by, at, id \\ nil)

        def new(
              %unquote(payload_mod){} = payload,
              %unquote(aggregate_id_mod){} = aggregate_id,
              %Version{} = aggregate_version,
              %unquote(by_mod){} = by,
              %EsEvent.At{} = at,
              id
            )
            when is_opt(id, EsEvent.ID) do
          id = id || EsEvent.ID.new()

          %__MODULE__{
            id: id,
            payload: payload,
            aggregate_id: aggregate_id,
            aggregate_version: aggregate_version,
            at: at,
            by: by
          }
        end
      end
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys
end
