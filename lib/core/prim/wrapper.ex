defmodule Core.Prim.Wrapper do
  @moduledoc """
  Протокол Prim-обёртки: метаданные (`label/0`, `native_kind/0`, `required_keys/0`,
  `optional_keys/0`, `expression_keys/0`), общие ключи опций и их передача в базовый `use Core.Prim`.

  По метаданным `Core.Prim.Opts.prepare!/3` разбирает опции `use` обёртки — один пролог на все
  обёртки вместо копии в каждой. Имя билдера (`label`) живёт в одном месте: оно уходит в текст
  `CompileError` и в диагностику вложенных `use`.

  Общие ключи (`name` — обязательный; `kind`, `mutate`, `validate`, `sensitive`, `personal`)
  обёртка не перечисляет: `required:` / `optional:` / `expression:` — только её собственные, а
  функции ключей отдают полный набор. Общие опции-выражения — `name`, `mutate`, `validate`.

  Владение общими ключами: `name`, `sensitive`, `personal` обёртка отдаёт базе как есть, и их
  проверяет `use Core.Prim` с меткой `Prim:`; `kind` (против `native_kind`), `mutate` и `validate`
  проверяет обёртка — `mutate` / `validate` она переименовывает в `custom_mutate` /
  `custom_validate` базы (`base_opts/2`).
  """

  alias Core.Helper

  @label "Prim.Wrapper"
  @required_keys ~w(label native_kind)a
  @optional_keys ~w(required optional expression)a
  @expression_keys ~w()a
  @common_required ~w(name)a
  @common_optional ~w(kind mutate validate sensitive personal)a
  @common_expression ~w(name mutate validate)a
  @steps [mutate: :custom_mutate, validate: :custom_validate]

  # ===== объявление =====

  @doc "Объявить метаданные Prim-обёртки: `label`, `native_kind`, собственные `required` / `optional` / `expression`."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    label = Helper.Opts.binary!(opts, :label, @label)
    native_kind = Helper.Opts.atom!(opts, :native_kind, @label)
    required = @common_required ++ atoms!(opts, :required)
    optional = @common_optional ++ atoms!(opts, :optional)
    expression = @common_expression ++ atoms!(opts, :expression)

    quote do
      @doc false
      @spec label() :: String.t()

      def label, do: unquote(label)

      @doc false
      @spec native_kind() :: atom()

      def native_kind, do: unquote(native_kind)

      @doc false
      @spec required_keys() :: [atom()]

      def required_keys, do: unquote(required)

      @doc false
      @spec optional_keys() :: [atom()]

      def optional_keys, do: unquote(optional)

      @doc false
      @spec expression_keys() :: [atom()]

      def expression_keys, do: unquote(expression)
    end
  end

  # ---

  defp atoms!(opts, key) do
    case Keyword.get(opts, key, []) do
      keys when is_list(keys) ->
        if Enum.all?(keys, &is_atom/1), do: keys, else: atoms_error!(key, keys)

      keys ->
        atoms_error!(key, keys)
    end
  end

  @spec atoms_error!(atom(), term()) :: no_return()

  defp atoms_error!(key, keys),
    do: Helper.Opts.reject!("#{@label}: #{key}", "ожидается список атомов, получено #{inspect(keys)}")

  # ===== опции базы =====

  @doc """
  Общие опции базового `use Core.Prim` из разобранных `Core.Prim.Opts.prepare!/3` опций обёртки.

  `name` уходит как есть, `kind` — резолвленный, `sensitive` / `personal` — заданные; `mutate` /
  `validate` обёртки становятся `custom_mutate` / `custom_validate` базы и проверяются в теле с
  меткой обёртки. Результат — keyword-AST: собственные опции базы обёртка дописывает к нему.
  """
  @spec base_opts(keyword(), String.t()) :: keyword()

  def base_opts(opts, label) when is_list(opts) and is_binary(label) do
    common = Keyword.take(opts, ~w(name kind sensitive personal)a)

    steps =
      for {key, base_key} <- @steps, Keyword.has_key?(opts, key) do
        {base_key, quote(do: Core.Prim.steps!(unquote(Keyword.fetch!(opts, key)), unquote(key), unquote(label)))}
      end

    common ++ steps
  end
end
