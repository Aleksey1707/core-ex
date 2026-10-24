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

  Опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов функции в
  опции — `CompileError` «ожидается литерал».

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

  alias Core.Helper

  @label "Labels.ID"
  @kinds ~w(ref user id)a
  @required_keys ~w(kind)a
  @optional_keys ~w(entity resolver)a
  @expression_keys []

  # ===== объявление =====

  @doc "Объявить вид id в сведениях (`kind:`), вид записи (`entity:`) и резолвер имён (`resolver:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    label_id = kind!(opts[:kind], opts[:entity], opts[:resolver])

    quote do
      Core.Labels.Check.prim!(
        Core.Prim.declared?(__MODULE__),
        Core.Labels.ID.declared?(__MODULE__) or Core.Labels.Text.declared?(__MODULE__),
        "Core.Labels.ID",
        unquote(@label)
      )

      @label_id unquote(Macro.escape(label_id))

      @doc false
      @spec __label_id__() :: Core.Labels.ID.t()

      def __label_id__, do: @label_id
    end
  end

  # ---

  defp kind!(:ref, entity, resolver), do: %{kind: :ref, entity: entity!(entity), resolver: resolver!(resolver)}

  defp kind!(:user, entity, resolver) do
    forbid!(:user, :entity, entity)
    %{kind: :user, entity: nil, resolver: resolver!(resolver)}
  end

  defp kind!(:id, entity, resolver) do
    forbid!(:id, :entity, entity)
    forbid!(:id, :resolver, resolver)
    %{kind: :id, entity: nil, resolver: nil}
  end

  defp kind!(kind, _entity, _resolver),
    do: Helper.Opts.reject!("#{@label}: kind", "ожидается один из #{inspect(@kinds)}, получено #{inspect(kind)}")

  defp entity!(nil), do: Helper.Opts.reject!(@label, "`kind: :ref` без `entity:` — вид записи атомом")
  defp entity!(entity) when is_atom(entity) and not is_boolean(entity), do: entity

  defp entity!(entity),
    do: Helper.Opts.reject!("#{@label}: entity", "ожидается атом вида записи, получено #{inspect(entity)}")

  defp resolver!(nil), do: Helper.Opts.reject!(@label, "вид id со ссылкой без `resolver:` — модуль резолвера имён")

  defp resolver!(resolver) do
    if is_atom(resolver) and String.starts_with?(Atom.to_string(resolver), "Elixir."),
      do: resolver,
      else: Helper.Opts.reject!("#{@label}: resolver", "ожидается модуль, получено #{inspect(resolver)}")
  end

  defp forbid!(_kind, _key, nil), do: :ok

  defp forbid!(kind, key, _value),
    do: Helper.Opts.reject!("#{@label}: #{key}", "у `kind: #{inspect(kind)}` не задаётся")

  # ===== интроспекция =====

  @doc false
  @spec declared?(module()) :: boolean()

  def declared?(module) when is_atom(module), do: Module.defines?(module, {:__label_id__, 0})

  @doc "Объявление вида id у Prim или `nil`, если Prim его не несёт."
  @spec find(module()) :: t() | nil

  def find(module) when is_atom(module) do
    if Core.Helper.Module.exports?(module, :__label_id__, 0), do: module.__label_id__()
  end
end
