defmodule Core.Field.Meta do
  @moduledoc false

  @typedoc false
  @type ctx :: %{
          role: atom() | nil,
          name: atom() | nil,
          where: String.t() | nil,
          spec: term(),
          fields: %{atom() => map()}
        }

  @callback key() :: atom()
  @callback roles() :: [atom()]
  @callback normalize!(raw :: term(), ctx :: ctx()) :: term()
  @callback read_extra(field :: map(), ctx :: ctx()) :: :none | {:union, Macro.t()}
  @callback write_reject(field :: map(), ctx :: ctx()) :: :ok | {:reject, String.t()}
  @callback plan_extra(path :: [atom()], field :: map(), ctx :: ctx()) :: [map()]
  @callback inspect_policy(field :: map(), ctx :: ctx()) :: :keep | :hide_value | :hide_all

  # Обработчик — модуль с колбэками поведения, но `@behaviour Core.Field.Meta` не объявляет:
  # список обработчиков ссылается на них отсюда, и обратная ссылка замкнула бы граф сборки
  # (`make xref`). Полноту колбэков проверяет `Core.Field.MetaTest`.
  @handlers [
    Core.Field.Meta.Optional,
    Core.Field.Meta.Wire,
    Core.Field.Meta.Default,
    Core.Field.Meta.Personal,
    Core.Field.Meta.Subject
  ]

  @field_keys %{optional: :optional?, wire: :wire, default: :default, personal: :personal, subject: :subject}
  @strictness %{keep: 0, hide_value: 1, hide_all: 2}

  # ===== реестр =====

  @doc false
  @spec registry() :: [module()]

  def registry, do: @handlers

  @doc false
  @spec keys() :: [atom()]

  def keys, do: Enum.map(@handlers, & &1.key())

  @doc false
  @spec fetch!(atom()) :: module()

  def fetch!(key) when is_atom(key) do
    Enum.find(@handlers, &(&1.key() == key)) ||
      raise ArgumentError, "нет обработчика метаданных поля #{inspect(key)}"
  end

  @doc false
  @spec allowed?(atom(), atom()) :: boolean()

  def allowed?(key, role) when is_atom(key) and is_atom(role), do: role in fetch!(key).roles()

  # ===== сборка поля =====

  @doc false
  @spec normalize!(map(), Core.Codec.Field.t(), ctx()) :: map()

  def normalize!(acc, %Core.Codec.Field{} = legacy, ctx) do
    Enum.reduce(@handlers, acc, fn handler, ir ->
      slot = Map.fetch!(@field_keys, handler.key())

      Map.replace!(ir, slot, handler.normalize!(Map.fetch!(legacy, slot), ctx))
    end)
  end

  # ===== вопросы по полям =====

  @doc false
  @spec read_type(map(), ctx()) :: :none | {:union, Macro.t()}

  def read_type(field, ctx) do
    case extras(@handlers, :read_extra, field, ctx) do
      [] -> :none
      [type] -> {:union, type}
      types -> {:union, Core.Codec.Field.union_type(types)}
    end
  end

  @doc false
  @spec write_reject?(map(), ctx()) :: String.t() | nil

  def write_reject?(field, ctx) do
    Enum.find_value(@handlers, fn handler ->
      case handler.write_reject(field, ctx) do
        {:reject, text} -> text
        :ok -> nil
      end
    end)
  end

  @doc false
  @spec plan([atom()], map(), ctx()) :: [map()]

  def plan(path, field, ctx), do: Enum.flat_map(@handlers, & &1.plan_extra(path, field, ctx))

  @doc false
  @spec personal?(map(), ctx()) :: boolean()

  def personal?(field, ctx), do: Core.Field.Meta.Personal.place?(field, ctx)

  @doc false
  @spec inspect_hidden([map()], ctx()) :: [atom()]

  def inspect_hidden(fields, ctx) do
    for %{name: name} = field <- fields, inspect_policy(field, ctx) == :hide_all, do: name
  end

  @doc false
  @spec inspect_policy(map(), ctx()) :: :keep | :hide_value | :hide_all

  def inspect_policy(field, ctx) do
    @handlers
    |> Enum.map(& &1.inspect_policy(field, ctx))
    |> Enum.max_by(&Map.fetch!(@strictness, &1))
  end

  # ---

  defp extras(handlers, callback, field, ctx) do
    for {:union, type} <- Enum.map(handlers, &apply(&1, callback, [field, ctx])), do: type
  end
end
