defmodule Core.Context.Accessor do
  @moduledoc """
  Билдер типизированного доступа к одному ключу `Context`.

  `use Context.Accessor, key: :current_user_id` генерирует `exists?/1`, `fetch/1`,
  `find/1`, `get/1`, `get!/1`, `put/2`, `delete/1` поверх `Context`.
  """

  alias Core.Helper

  @required_keys ~w(key)a
  @optional_keys ~w()a

  @doc "Типизированный accessor ключа Context (`key:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Context.Accessor.required_keys(),
        Core.Context.Accessor.optional_keys(),
        "Context.Accessor"
      )

      @context_key Keyword.fetch!(opts, :key)
      alias Core.Context
      alias Core.Error

      @doc "Есть ли значение по ключу."
      @spec exists?(Context.t()) :: boolean()

      def exists?(context), do: Context.exists?(context, @context_key)

      @doc "Значение как `{:ok, value}` / `:error` (отличает сохранённый `nil`)."
      @spec fetch(Context.t()) :: {:ok, term()} | :error

      def fetch(context), do: Context.fetch(context, @context_key)

      @doc "Найти значение или `nil`."
      @spec find(Context.t()) :: term() | nil

      def find(context), do: Context.find(context, @context_key)

      @doc "Получить значение; при отсутствии — ошибка."
      @spec get(Context.t()) :: {:ok, term()} | {:error, Error.t()}

      def get(context), do: Context.get(context, @context_key)

      @doc "Получить значение; при отсутствии — raise."
      @spec get!(Context.t()) :: term()

      def get!(context), do: Context.get!(context, @context_key)

      @doc "Записать значение по ключу."
      @spec put(Context.t(), term()) :: Context.t()

      def put(context, value), do: Context.put(context, @context_key, value)

      @doc "Удалить значение по ключу."
      @spec delete(Context.t()) :: Context.t()

      def delete(context), do: Context.delete(context, @context_key)
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys
end
