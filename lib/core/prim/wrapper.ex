defmodule Core.Prim.Wrapper do
  @moduledoc """
  Интроспекция Prim-обёртки: `label/0`, `native_kind/0`, `required_keys/0`,
  `optional_keys/0`.

  По ним `Core.Prim.Opts.prepare!/2` проверяет опции `use` — один порядок проверок на
  все обёртки вместо копии пролога в каждой. Имя билдера (`label`) живёт в одном месте:
  оно уходит и в текст `CompileError`, и в диагностику вложенных `use`.
  """

  alias Core.Helper

  @doc "Объявить метаданные Prim-обёртки (`label` / `native_kind` / `required` / `optional`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(label native_kind required optional)a, [], "Prim.Wrapper")

      @wrapper_label Keyword.fetch!(opts, :label)
      @wrapper_native_kind Keyword.fetch!(opts, :native_kind)
      @wrapper_required Keyword.fetch!(opts, :required)
      @wrapper_optional Keyword.fetch!(opts, :optional)

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
end
