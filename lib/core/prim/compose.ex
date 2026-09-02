defmodule Core.Prim.Compose do
  @moduledoc """
  Билдер Prim-обёртки над другим Prim (`of:`): `%Mod{value: %Base{}}`.

  Kind по умолчанию `:composite`; wire-формат композита совпадает с форматом базового
  Prim. `new/1` принимает raw базы, `%Base{}` или `%Mod{}` (идемпотентно), вложенная
  композиция допустима. Дополнительно: `__domain_base__/0`, `raw/1`.
  Чувствительность наследуется от базового Prim, если не задана явно.
  """

  alias Core.Error
  alias Core.Helper
  alias Core.Prim

  @native_kind :composite
  @required_keys ~w(name of)a
  @optional_keys ~w(kind mutate validate sensitive)a

  @doc "Объявить Compose-Prim поверх базового (`of:` / `name:`)."
  defmacro __using__(opts) do
    base = Keyword.fetch!(opts, :of)

    quote bind_quoted: [opts: opts], unquote: true do
      Helper.Opts.validate!(
        opts,
        Core.Prim.Compose.required_keys(),
        Core.Prim.Compose.optional_keys(),
        "Prim.Compose"
      )

      base = Keyword.fetch!(opts, :of)
      Code.ensure_compiled!(base)

      if not Prim.prim?(base) do
        raise CompileError,
          description: "of: must be a Prim module, got: #{inspect(base)}"
      end

      native = Core.Prim.Compose.native_kind()
      kind = Keyword.get(opts, :kind, native)
      Prim.validate_kind!(native, kind)

      @base base

      @doc false
      @spec __compose_cast__(term()) :: {:ok, term()} | {:error, Error.t()}

      def __compose_cast__(raw) do
        Core.Prim.Compose.cast(raw, @base, __MODULE__)
      end

      use Prim,
        cast: &__MODULE__.__compose_cast__/1,
        custom_mutate: Keyword.get(opts, :mutate),
        custom_validate: Keyword.get(opts, :validate),
        name: Keyword.fetch!(opts, :name),
        kind: kind,
        sensitive: Core.Prim.Compose.sensitive?(opts, unquote(base)),
        value_type: unquote(base).t()

      @doc "Модуль базового Prim."
      @spec __domain_base__() :: module()

      def __domain_base__, do: @base

      @doc "Самое внутреннее не-Prim значение."
      @spec raw(t()) :: term()

      def raw(%__MODULE__{} = prim), do: Prim.unwrap(prim)
    end
  end

  @doc """
  Чувствительность композита: явная опция или наследование от базового Prim.
  """
  @spec sensitive?(keyword(), module()) :: boolean()

  def sensitive?(opts, base) when is_list(opts) and is_atom(base) do
    case Keyword.fetch(opts, :sensitive) do
      {:ok, sensitive} -> sensitive
      :error -> base_sensitive?(base)
    end
  end

  # ---

  defp base_sensitive?(base) do
    (:erlang.module_loaded(base) or Code.ensure_loaded?(base)) and
      function_exported?(base, :__domain_sensitive__, 0) and
      base.__domain_sensitive__()
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec native_kind() :: atom()

  def native_kind, do: @native_kind

  @doc "Cast: базовый Prim / себя / raw через `base.new/1`."
  @spec cast(term(), module(), module()) :: {:ok, term()} | {:error, Error.t()}

  def cast(%base{} = prim, base, _self), do: {:ok, prim}

  def cast(%self{value: value}, _base, self), do: {:ok, value}

  def cast(raw, base, _self) when is_atom(base), do: base.new(raw)
end
