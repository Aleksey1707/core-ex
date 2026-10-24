defmodule Core.Es.Event do
  @moduledoc """
  Базовый builder отдельного события версионированного агрегата (`use`).

  ```elixir
  use Core.Es.Event,
    family: Account.Event,
    payload: Payload
  ```

  - `family:` — семейство событий агрегата (`use Core.Es.Event.Family`): у него событие берёт Prim
    агрегата и автора и запекает их в головы `new/5,6`, `@type t` и `@spec`. Опций
    `aggregate_id:` / `by:` у события нет — старая форма даёт `CompileError` с недостающими и
    неизвестными опциями.
  - `payload:` — модуль нагрузки или `nil` (событие без нагрузки). Модуль MAY быть вложен в событие:
    проверки по нему (`subject: :aggregate_id` у поля нагрузки) идут в теле события. Вложенный модуль
    MUST быть объявлен выше `use` — ниже он ещё не собран, и сборка падает `CompileError` «недоступен».

  Wire-имя события задаётся в `<Aggregate>.Event.Codec`, не здесь. Оттуда же читается
  интроспекция события — `__es_payload__/0`, `__es_aggregate_id__/0`, `__es_by__/0`,
  `__es_family__/0`. Prim агрегата и автора кодек берёт у семейства `family:`, а `__es_family__/0`
  событий сверяет с ним (`событие <E> не из семейства <F>`); по `__es_payload__/0` кодек строит
  клаузы нагрузки. `__es_family__/0` читает и проекция, чтобы найти кодек события.

  ## Черновик события

  Элемент результата `decide/2` агрегата строит само событие — `draft`:

  - `draft(%Payload{} = payload)` → `{Event.Mod, payload}` у события с нагрузкой;
  - `draft()` → `Event.Mod` у события без нагрузки.

  Модуль нагрузки стоит в голове литералом, поэтому нагрузку другого события и не-struct ловит
  вывод типов при сборке вызывающего, а `draft()` у события с нагрузкой и `draft(payload)` у
  события без неё — предупреждение о неопределённой функции. Модуль нагрузки, общий у нескольких
  событий, ошибкой не является: `draft` у каждого события свой. Событие другого агрегата сборка не
  ловит — `FunctionClauseError` при исполнении команды (`Core.Es.Aggregate`). Возвращается элемент
  `Core.Es.Aggregate.result()`, так что `Core.Es.Aggregate.Test.given/3` и тесты, сравнивающие
  результат `decide/2` с кортежами, не меняются.

  Черновик живёт в событии, а не в кодеке агрегата: он не касается wire, а пару «событие —
  нагрузка» событие знает само из `payload:`.

  Макрос занимает в модуле события имя `draft/1` (с нагрузкой) или `draft/0` (без неё).
  """

  import Core.Helper.String, only: [first_line: 1]

  alias Core.Codec.Field
  alias Core.Es.Event.Payload
  alias Core.Helper
  alias Core.Helper.FieldCheck
  alias Core.Version

  defmodule ID do
    @moduledoc """
    Идентификатор события
    """

    use Core.Prim.UUID,
      name: first_line(@moduledoc),
      version: 7
  end

  defmodule OperationID do
    @moduledoc """
    Идентификатор операции

    Операция — изменение одной транзакции записи; основание события — тоже операция.
    """

    use Core.Prim.UUID,
      name: first_line(@moduledoc),
      version: 7
  end

  defmodule SessionID do
    @moduledoc """
    Идентификатор сеанса инициатора

    Что считать сеансом, решает приложение: значение кладёт его web-слой
    (`Core.Context.Session`), библиотека id сеанса не выпускает.
    """

    use Core.Prim.UUID,
      name: first_line(@moduledoc),
      version: :external
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
          required(:by) => term(),
          required(:operation_id) => OperationID.t() | nil,
          required(:session_id) => SessionID.t() | nil,
          required(:basis_id) => OperationID.t() | nil
        }

  @label "Es.Event"
  @required_keys ~w(family payload)a
  @optional_keys ~w()a

  # ===== объявление =====

  @doc "Объявить событие агрегата (`family:` / `payload:`)."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)

    payload_mod = Keyword.fetch!(lit, :payload)
    family_mod = Helper.Opts.module!(lit, :family, @label, exports: [__es_aggregate_id__: 0, __es_by__: 0])
    aggregate_id_mod = family_mod.__es_aggregate_id__()
    by_mod = family_mod.__es_by__()

    unless is_nil(payload_mod) or is_atom(payload_mod) do
      raise CompileError, description: "#{@label}: :payload должен быть модулем или nil"
    end

    payload = payload_parts(payload_mod)

    quote do
      Core.Es.Event.payload!(unquote(Macro.escape(payload_mod)), unquote(aggregate_id_mod))

      alias Core.Es.Event, as: EsEvent
      alias Core.Version

      import Core.Guard, only: [is_opt: 2]

      @enforce_keys ~w(id payload aggregate_id aggregate_version at by)a
      defstruct @enforce_keys ++ [operation_id: nil, session_id: nil, basis_id: nil]

      @doc false
      @spec __es_payload__() :: module() | nil

      def __es_payload__, do: unquote(payload_mod)

      @doc false
      @spec __es_aggregate_id__() :: module()

      def __es_aggregate_id__, do: unquote(aggregate_id_mod)

      @doc false
      @spec __es_by__() :: module()

      def __es_by__, do: unquote(by_mod)

      @doc false
      @spec __es_family__() :: module()

      def __es_family__, do: unquote(family_mod)

      @type t :: %__MODULE__{
              id: EsEvent.ID.t(),
              payload: unquote(payload.type),
              aggregate_id: unquote(aggregate_id_mod).t(),
              aggregate_version: Version.t(),
              at: EsEvent.At.t(),
              by: unquote(by_mod).t(),
              operation_id: EsEvent.OperationID.t() | nil,
              session_id: EsEvent.SessionID.t() | nil,
              basis_id: EsEvent.OperationID.t() | nil
            }

      @doc unquote(payload.draft_doc)
      @spec draft(unquote_splicing(payload.specs)) :: unquote(payload.draft_spec)

      def draft(unquote_splicing(payload.heads)), do: unquote(payload.draft)

      @doc unquote(payload.new_doc)
      @spec new(
              unquote_splicing(payload.specs),
              unquote(aggregate_id_mod).t(),
              Version.t(),
              unquote(by_mod).t(),
              EsEvent.At.t(),
              EsEvent.ID.t() | nil
            ) :: t()

      def new(unquote_splicing(payload.args), aggregate_id, aggregate_version, by, at, id \\ nil)

      def new(
            unquote_splicing(payload.heads),
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
          payload: unquote(payload.value),
          aggregate_id: aggregate_id,
          aggregate_version: aggregate_version,
          at: at,
          by: by
        }
      end
    end
  end

  # ---

  defp payload_parts(nil) do
    %{
      type: nil,
      specs: [],
      args: [],
      heads: [],
      value: nil,
      draft_spec: quote(do: __MODULE__),
      draft: quote(do: __MODULE__),
      draft_doc: "Черновик события без нагрузки — элемент результата `decide/2` агрегата.",
      new_doc: "Создать событие без нагрузки. Опциональный `id` — для восстановления из хранилища."
    }
  end

  defp payload_parts(payload_mod) do
    %{
      type: quote(do: unquote(payload_mod).t()),
      specs: [quote(do: unquote(payload_mod).t())],
      args: [quote(do: payload)],
      heads: [quote(do: %unquote(payload_mod){} = payload)],
      value: quote(do: payload),
      draft_spec: quote(do: {__MODULE__, unquote(payload_mod).t()}),
      draft: quote(do: {__MODULE__, payload}),
      draft_doc: "Черновик события с нагрузкой — элемент результата `decide/2` агрегата.",
      new_doc: "Создать событие. Опциональный `id` — для восстановления из хранилища."
    }
  end

  # ===== проверки сборки =====

  @doc false
  @spec declared?(module()) :: boolean()

  def declared?(module) when is_atom(module), do: Module.defines?(module, {:__es_payload__, 0})

  # Модуль нагрузки MAY быть вложен в событие: при раскрытии `use` он ещё не собран, поэтому проверки по
  # нему — в теле, и несобранный модуль — отказ, а не тихий пропуск. `subject: :aggregate_id` у поля
  # нагрузки по полям требует UUID-Prim агрегата: идентификатор субъекта — UUID (ADR-0073). Нагрузку
  # другого вида проверять нечем.
  @doc false
  @spec payload!(module() | nil, module()) :: module() | nil

  def payload!(nil, _aggregate_id), do: nil

  def payload!(payload, aggregate_id) when is_atom(payload) and is_atom(aggregate_id) do
    FieldCheck.module!(payload, "#{@label}: payload")
    check_subject!(payload, aggregate_id)
    payload
  end

  # ---

  defp check_subject!(payload, aggregate_id) do
    with true <- Helper.Module.exports?(payload, :__es_payload_fields__, 0),
         [{name, :aggregate_id} | _rest] <- aggregate_subjects(payload),
         false <- Payload.uuid_prim?(aggregate_id) do
      raise CompileError,
        description:
          "#{@label}: поле #{name} нагрузки #{inspect(payload)} объявлено с subject: :aggregate_id, " <>
            "а aggregate_id: #{inspect(aggregate_id)} — не Prim.UUID и не Prim.Compose над ним"
    end

    :ok
  end

  defp aggregate_subjects(payload),
    do: Enum.filter(Field.subjects(payload.__es_payload_fields__()), &match?({_name, :aggregate_id}, &1))
end
