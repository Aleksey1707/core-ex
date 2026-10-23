defmodule Core.Labels.ID do
  @moduledoc """
  Вид id в сведениях события — как Prim-идентификатор выходит человеку (ADR-0063).

  Подключается в Prim-идентификаторе после `use Core.Prim.*`:

      defmodule MyApp.Domain.Sales.Account.ID do
        use Core.Prim.UUID,
          name: "Счёт",
          version: 7

        use Core.Labels.ID,
          kind: :ref,
          entity: :account,
          resolver: MyApp.Domain.Sales.Account.Query
      end

  | `kind:` | В сведениях (`Core.Labels.Details`) | Опции |
  |---|---|---|
  | `:ref` | ссылка на запись `%{kind: :ref, entity: вид записи, value: id}` | `entity:` — атом, `resolver:` |
  | `:user` | ссылка на учётную запись `%{kind: :user, value: id}` | `resolver:` |
  | `:id` | только id, текстом `%{kind: :text, value: id}`: имени человеку не называют | — |

  Вид записи — атом: camelCase на wire делает wire, а не домен. Резолвер — модуль, который отдаёт
  текущее имя по id: его вызывает словарь ссылок страницы событий.

  Сборку ломают: `kind:` вне `~w(ref user id)a`, `entity:` не атомом или не у `:ref`, `resolver:` не
  модулем или у `:id`, отсутствие обязательной опции своего вида, `use` не после `use Core.Prim.*` и
  `use Core.Labels.Text` в том же Prim — у значения один способ выйти в сведения.

  Prim-идентификатор без объявления в сведениях — исключение `Core.Labels.Details.build/1`.

  Макрос занимает в Prim имя `__label_id__/0`.
  """

  @typedoc "Вид id в сведениях."
  @type kind :: :ref | :user | :id

  @typedoc "Объявление вида id."
  @type t :: %{kind: kind(), entity: atom() | nil, resolver: module() | nil}

  @label "Labels.ID"
  @kinds ~w(ref user id)a
  @required_keys ~w(kind)a
  @optional_keys ~w(entity resolver)a

  # ===== объявление =====

  @doc "Объявить вид id в сведениях (`kind:`), вид записи (`entity:`) и резолвер имён (`resolver:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Core.Helper.Opts.validate!(
        opts,
        Core.Labels.ID.required_keys(),
        Core.Labels.ID.optional_keys(),
        "Labels.ID"
      )

      Core.Labels.Check.prim!(
        Core.Prim.declared?(__MODULE__),
        Core.Labels.ID.declared?(__MODULE__) or Core.Labels.Text.declared?(__MODULE__),
        "Core.Labels.ID",
        "Labels.ID #{inspect(__MODULE__)}"
      )

      @label_id Core.Labels.ID.declare!(__MODULE__, opts)

      @doc false
      @spec __label_id__() :: Core.Labels.ID.t()

      def __label_id__, do: @label_id
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec declare!(module(), keyword()) :: t()

  def declare!(module, opts) when is_atom(module) and is_list(opts),
    do: kind!(module, Keyword.fetch!(opts, :kind), Keyword.get(opts, :entity), Keyword.get(opts, :resolver))

  # ---

  defp kind!(module, :ref, entity, resolver),
    do: %{kind: :ref, entity: entity!(module, entity), resolver: resolver!(module, resolver)}

  defp kind!(module, :user, entity, resolver) do
    forbid!(module, :user, :entity, entity)
    %{kind: :user, entity: nil, resolver: resolver!(module, resolver)}
  end

  defp kind!(module, :id, entity, resolver) do
    forbid!(module, :id, :entity, entity)
    forbid!(module, :id, :resolver, resolver)
    %{kind: :id, entity: nil, resolver: nil}
  end

  defp kind!(module, kind, _entity, _resolver),
    do: reject!(module, "kind: один из #{inspect(@kinds)}, задано #{inspect(kind)}")

  defp entity!(module, nil), do: reject!(module, "`kind: :ref` без `entity:` — вид записи атомом")
  defp entity!(_module, entity) when is_atom(entity) and not is_boolean(entity), do: entity
  defp entity!(module, entity), do: reject!(module, "entity: атом вида записи, задано #{inspect(entity)}")

  defp resolver!(module, nil), do: reject!(module, "вид id со ссылкой без `resolver:` — модуль резолвера имён")

  defp resolver!(module, resolver) do
    if is_atom(resolver) and String.starts_with?(Atom.to_string(resolver), "Elixir."),
      do: resolver,
      else: reject!(module, "resolver: модуль, задано #{inspect(resolver)}")
  end

  defp forbid!(_module, _kind, _key, nil), do: :ok
  defp forbid!(module, kind, key, _value), do: reject!(module, "`#{key}:` у `kind: #{inspect(kind)}` не задаётся")

  defp reject!(module, message), do: raise(CompileError, description: "#{where(module)}: #{message}")

  defp where(module), do: "#{@label} #{inspect(module)}"

  # ===== интроспекция =====

  @doc false
  @spec declared?(module()) :: boolean()

  def declared?(module) when is_atom(module), do: Module.defines?(module, {:__label_id__, 0})

  @doc "Объявление вида id у Prim или `nil`, если Prim его не несёт."
  @spec find(module()) :: t() | nil

  def find(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__label_id__, 0), do: module.__label_id__()
  end
end
