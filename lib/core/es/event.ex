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

  Обе опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов функции —
  `CompileError` «ожидается литерал».

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
  @expression_keys ~w()a
  @payload_where "#{@label}: payload"

  # ===== объявление =====

  @doc "Объявить событие агрегата (`family:` / `payload:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    payload_mod = payload_form!(Keyword.fetch!(opts, :payload))
    family_mod = Helper.Opts.module!(opts, :family, @label, exports: [__es_aggregate_id__: 0, __es_by__: 0])
    aggregate_id_mod = family_mod.__es_aggregate_id__()
    by_mod = family_mod.__es_by__()
    payload = payload_parts(payload_mod)

    quote do
      unquote(draft_entries(payload_mod))
      Core.Es.Event.payload!(unquote(Macro.escape(payload_mod)), unquote(aggregate_id_mod))

      @es_personal_payload Core.Es.Event.personal_payload?(unquote(Macro.escape(payload_mod)))

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

      @es_read_type {unquote(Macro.escape(payload_mod)), unquote(Macro.escape(aggregate_id_mod)),
                     unquote(Macro.escape(by_mod))}
      @before_compile Core.Es.Event

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

  @doc """
  Тип чтения события: корневое ПДн-место нагрузки-Prim (`personal: true` у Prim) допускает
  `%Core.Es.Personal.Destroyed{}`; `new/N` остаётся типом записи — уничтоженное собирает загрузка
  (`build/3`, клауза с уничтоженной нагрузкой).

  Флаг считается в теле модуля события, а не при раскрытии `use`: при раскрытии нагрузка бывает
  ещё не собрана (`Account → Event.Codec → Event → Account.Holder` — `Code.ensure_compiled` дал бы
  `:unavailable`).
  """
  defmacro __before_compile__(env) do
    {payload_mod, aggregate_id_mod, by_mod} = Module.get_attribute(env.module, :es_read_type)
    personal? = Module.get_attribute(env.module, :es_personal_payload) == true

    payload_type =
      cond do
        is_nil(payload_mod) -> quote(do: nil)
        personal? -> quote(do: unquote(payload_mod).t() | Core.Es.Personal.Destroyed.t())
        true -> quote(do: unquote(payload_mod).t())
      end

    quote do
      @type t :: %__MODULE__{
              id: Core.Es.Event.ID.t(),
              payload: unquote(payload_type),
              aggregate_id: unquote(aggregate_id_mod).t(),
              aggregate_version: Core.Version.t(),
              at: Core.Es.Event.At.t(),
              by: unquote(by_mod).t(),
              operation_id: Core.Es.Event.OperationID.t() | nil,
              session_id: Core.Es.Event.SessionID.t() | nil,
              basis_id: Core.Es.Event.OperationID.t() | nil
            }
    end
  end

  @doc false
  @spec personal_payload?(module() | nil) :: boolean()

  def personal_payload?(nil), do: false

  def personal_payload?(payload_mod) when is_atom(payload_mod) do
    Helper.Module.exports?(payload_mod, :__domain_personal__, 0) and payload_mod.__domain_personal__()
  end

  # ---

  defp payload_form!(payload) when is_atom(payload), do: payload

  defp payload_form!(payload),
    do: Helper.Opts.reject!(@payload_where, "ожидается модуль или nil, получено #{inspect(payload)}")

  defp payload_parts(nil) do
    %{
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
    draft =
      quote generated: true do
        Core.Es.Personal.Plan.assert_writable!(payload, @es_draft_entries)
        {__MODULE__, payload}
      end

    %{
      specs: [quote(do: unquote(payload_mod).t())],
      args: [quote(do: payload)],
      heads: [quote(do: %unquote(payload_mod){} = payload)],
      value: quote(do: payload),
      draft_spec: quote(do: {__MODULE__, unquote(payload_mod).t()}),
      draft: draft,
      draft_doc: "Черновик события с нагрузкой — элемент результата `decide/2` агрегата.",
      new_doc: "Создать событие. Опциональный `id` — для восстановления из хранилища."
    }
  end

  # План записи — в теле модуля, а не при раскрытии `use`: вложенная нагрузка объявлена выше, но
  # тело раскрывается целиком до исполнения, и `__core_fields__/0` у неё ещё нет.
  defp draft_entries(nil), do: nil

  defp draft_entries(payload_mod) do
    quote generated: true do
      @es_draft_entries Core.Es.Personal.Plan.runtime_entries(List.wrap(Core.Field.introspect(unquote(payload_mod))))
    end
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
    FieldCheck.module!(payload, @payload_where)
    check_subject!(payload, aggregate_id)
    payload
  end

  # ---

  defp check_subject!(payload, aggregate_id) do
    with true <- Payload.wire_payload?(payload),
         [{name, :aggregate_id} | _rest] <- aggregate_subjects(payload),
         false <- Payload.uuid_prim?(aggregate_id) do
      Helper.Opts.reject!(
        @payload_where,
        "поле #{name} нагрузки #{inspect(payload)} объявлено с subject: :aggregate_id, " <>
          "а aggregate_id: #{inspect(aggregate_id)} — не Prim.UUID и не Prim.Compose над ним"
      )
    end

    :ok
  end

  defp aggregate_subjects(payload) do
    for %{path: path, subject: :aggregate_id} <- Core.Es.Personal.Plan.entries(Core.Field.introspect(payload)) do
      {List.last(path), :aggregate_id}
    end
  end
end
