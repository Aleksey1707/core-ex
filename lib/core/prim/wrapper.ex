defmodule Core.Prim.Wrapper do
  @moduledoc """
  Протокол Prim-обёртки: метаданные (`label/0`, `native_kind/0`, `required_keys/0`,
  `optional_keys/0`), общие ключи опций и их передача в базовый `use Core.Prim`.

  По метаданным `Core.Prim.Opts.prepare!/2` проверяет опции `use` — один порядок проверок на
  все обёртки вместо копии пролога в каждой. Имя билдера (`label`) живёт в одном месте:
  оно уходит и в текст `CompileError`, и в диагностику вложенных `use`.

  Общие ключи (`name` — обязательный; `kind`, `mutate`, `validate`, `sensitive`, `personal`)
  обёртка не перечисляет: `required:` / `optional:` — только её собственные, а
  `required_keys/0` / `optional_keys/0` отдают полный набор. В базу общие ключи передаёт
  `use_prim/3`: `mutate` / `validate` обёртки становятся `custom_mutate` / `custom_validate` базы.
  """

  alias Core.Helper

  @required_keys ~w(label native_kind)a
  @optional_keys ~w(required optional)a
  @common_required ~w(name)a
  @flags ~w(sensitive personal)a
  @common_optional ~w(kind mutate validate)a ++ @flags
  @base_keys ~w(name kind custom_mutate custom_validate)a ++ @flags

  @doc "Объявить метаданные Prim-обёртки (`label` / `native_kind` / собственные `required` / `optional`)."
  defmacro __using__(opts) do
    quote bind_quoted: [
            opts: opts,
            required_keys: @required_keys,
            optional_keys: @optional_keys,
            common_required: @common_required,
            common_optional: @common_optional
          ] do
      Helper.Opts.validate!(opts, required_keys, optional_keys, "Prim.Wrapper")

      @wrapper_label Keyword.fetch!(opts, :label)
      @wrapper_native_kind Keyword.fetch!(opts, :native_kind)
      @wrapper_required common_required ++ Keyword.get(opts, :required, [])
      @wrapper_optional common_optional ++ Keyword.get(opts, :optional, [])

      @doc false
      @spec label() :: String.t()

      def label, do: @wrapper_label

      @doc false
      @spec native_kind() :: atom()

      def native_kind, do: @wrapper_native_kind

      @doc false
      @spec required_keys() :: [atom()]

      def required_keys, do: @wrapper_required

      @doc false
      @spec optional_keys() :: [atom()]

      def optional_keys, do: @wrapper_optional
    end
  end

  @doc """
  Объявить базовый Prim обёртки: общие ключи из `opts` (`base_opts/2`) и собственные `own`.

  `own` — литерал keyword (`cast:`, `mutate:`, `validate:`, `type_opts:`, `pipeline_opts:`,
  `value_type:`); его ключи перекрывают общие (`Prim.Compose` подставляет унаследованные флаги).
  Опции базы уходят литералом keyword: `use Core.Prim` снимает `value_type:` с AST до вычисления
  опций, и выражение вместо литерала (`base_opts ++ own`) его бы не отдало.
  """
  defmacro use_prim(opts, kind, own) do
    common = Enum.map(@base_keys, &{&1, quote(do: Keyword.fetch!(base, unquote(&1)))})

    quote do
      base = Core.Prim.Wrapper.base_opts(unquote(opts), unquote(kind))

      use Core.Prim, unquote(Keyword.merge(common, own))
    end
  end

  @doc "Опции базового `use Core.Prim` из общих ключей обёртки; `kind` — резолвленный `prepare!/2`."
  @spec base_opts(keyword(), atom()) :: keyword()

  def base_opts(opts, kind) when is_list(opts) and is_atom(kind) do
    [
      name: Keyword.fetch!(opts, :name),
      kind: kind,
      custom_mutate: Keyword.get(opts, :mutate),
      custom_validate: Keyword.get(opts, :validate)
    ] ++ Enum.map(@flags, &{&1, Keyword.get(opts, &1, false)})
  end

  @doc "Общие флаги обёртки: boolean-опции, которые проверяет `Core.Prim.Opts.prepare!/2`."
  @spec flags() :: [atom()]

  def flags, do: @flags
end
