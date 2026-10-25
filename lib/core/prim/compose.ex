defmodule Core.Prim.Compose do
  @moduledoc """
  Билдер Prim-обёртки над другим Prim (`of:`): `%Mod{value: %Base{}}`.

  Kind по умолчанию `:composite`; wire-формат композита совпадает с форматом базового
  Prim. `new/1` принимает raw базы, `%Base{}` или `%Mod{}` (идемпотентно), вложенная
  композиция допустима. Дополнительно: `__domain_base__/0`, `raw/1`.

  Флаги `sensitive:` и `personal:` наследуются от базового Prim, если не заданы явно; понизить
  флаг (`sensitive: false` поверх чувствительной базы, `personal: false` поверх персональной)
  нельзя — `CompileError`.

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:` — проверяются в
  теле модуля; остальные опции — литералы.
  `of:` — модуль-литерал: проверяется при раскрытии и MUST NOT быть вложен в вызывающего.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.Compose",
    native_kind: :composite,
    required: ~w(of)a

  @doc "Объявить Compose-Prim поверх базового (`of:` / `name:`)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    base = Keyword.fetch!(opts, :of)

    base_opts =
      Keyword.merge(Prim.Wrapper.base_opts(opts, label()),
        cast: quote(do: &__MODULE__.__compose_cast__/1),
        sensitive: sensitive?(opts, base),
        personal: personal?(opts, base),
        value_type: quote(do: unquote(base).t())
      )

    quote do
      @base unquote(base)

      @doc false
      @spec __compose_cast__(term()) :: Core.Result.t()

      def __compose_cast__(raw) do
        Core.Prim.Compose.cast(raw, @base, __MODULE__)
      end

      use Core.Prim, unquote(base_opts)

      @doc "Модуль базового Prim."
      @spec __domain_base__() :: module()

      def __domain_base__, do: @base

      @doc "Самое внутреннее не-Prim значение."
      @spec raw(t()) :: term()

      def raw(%__MODULE__{} = prim), do: Prim.unwrap(prim)
    end
  end

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.boolean!(opts, ~w(sensitive personal)a, label())
    ensure_base!(Helper.Opts.module!(opts, :of, label()))
  end

  @doc "Cast: базовый Prim / себя / raw через `base.new/1`."
  @spec cast(term(), module(), module()) :: Result.t()

  def cast(%base{} = prim, base, _self), do: {:ok, prim}
  def cast(%self{value: value}, _base, self), do: {:ok, value}
  def cast(raw, base, _self) when is_atom(base), do: base.new(raw)

  @doc """
  Чувствительность композита: явная опция или наследование от базового Prim.

  Понижение запрещено: `sensitive: false` поверх чувствительной базы отменил бы
  редактирование `Error.detail` на уровне композита, и raw ушёл бы в лог целым —
  база успевает защитить только свой собственный `detail` внутри `parent`.
  """
  @spec sensitive?(keyword(), module()) :: boolean()

  def sensitive?(use_opts, base) when is_list(use_opts) and is_atom(base) do
    inherit(use_opts, base, :sensitive, "чувствительного")
  end

  @doc """
  Персональность композита: явная опция или наследование от базового Prim.

  Понижение запрещено по той же причине, что у `sensitive?/2`: `personal: false` поверх
  персональной базы открыл бы raw базы в `Error.detail` композита.
  """
  @spec personal?(keyword(), module()) :: boolean()

  def personal?(use_opts, base) when is_list(use_opts) and is_atom(base) do
    inherit(use_opts, base, :personal, "персонального")
  end

  # ---

  defp ensure_base!(base) do
    if not Prim.prim?(base) do
      Helper.Opts.reject!("#{label()}: of", "ожидается Prim-модуль, получено #{inspect(base)}")
    end

    :ok
  end

  defp inherit(opts, base, flag, adjective) do
    case Keyword.fetch(opts, flag) do
      {:ok, false} -> refuse_downgrade!(base, flag, adjective)
      {:ok, value} -> value
      :error -> base_flag?(base, flag)
    end
  end

  defp refuse_downgrade!(base, flag, adjective) do
    if base_flag?(base, flag) do
      Helper.Opts.reject!(
        "#{label()}: #{flag}",
        "false поверх #{adjective} #{inspect(base)} — композит открыл бы raw базы в Error.detail; уберите опцию"
      )
    end

    false
  end

  defp base_flag?(base, flag) do
    getter = getter(flag)

    Core.Helper.Module.exports?(base, getter, 0) and apply(base, getter, [])
  end

  defp getter(:sensitive), do: :__domain_sensitive__
  defp getter(:personal), do: :__domain_personal__
end
