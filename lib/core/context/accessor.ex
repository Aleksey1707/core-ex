defmodule Core.Context.Accessor do
  @moduledoc """
  Билдер типизированного доступа к одному ключу `Context`.

  `use Context.Accessor, key: :current_user_id` генерирует `exists?/1`, `find/1`,
  `get/1`, `get!/1`, `put/2`, `delete/1` поверх `Context`; каждая — `defoverridable`.

  `type:` — модуль значения (Prim, агрегат, ...): спеки сужаются с `term()` до `<Mod>.t()`,
  а `put/2` принимает только `%<Mod>{}` — чужое значение отсекается на компиляции, а не
  всплывает в репозитории.

  Макрос инжектирует в модуль-потребитель `alias Core.Context` и `alias Core.Error`:
  на них ссылаются сгенерированные спеки.

      defmodule CurrentUser do
        use Core.Context.Accessor,
          key: :current_user_id,
          type: User.ID
      end
  """

  alias Core.Helper

  @required_keys ~w(key)a
  @optional_keys ~w(type)a

  @doc "Типизированный accessor ключа Context (`key:` + опциональный `type:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Context.Accessor.required_keys(),
        Core.Context.Accessor.optional_keys(),
        "Context.Accessor"
      )

      alias Core.Context
      alias Core.Error

      @context_accessor_key Helper.Opts.atom!(opts, :key, "Context.Accessor")

      context_accessor_type =
        if Keyword.has_key?(opts, :type),
          do: Helper.Opts.module!(opts, :type, "Context.Accessor"),
          else: nil

      context_accessor_value =
        if is_nil(context_accessor_type),
          do: quote(do: term()),
          else: quote(do: unquote(context_accessor_type).t())

      @doc "Есть ли значение по ключу."
      @spec exists?(Context.t()) :: boolean()

      def exists?(%Context{} = context), do: Context.exists?(context, @context_accessor_key)

      @doc "Найти значение или `nil`."
      @spec find(Context.t()) :: unquote(context_accessor_value) | nil

      def find(%Context{} = context), do: Context.find(context, @context_accessor_key)

      @doc "Получить значение; при отсутствии — ошибка."
      @spec get(Context.t()) :: {:ok, unquote(context_accessor_value)} | {:error, Error.t()}

      def get(%Context{} = context), do: Context.get(context, @context_accessor_key)

      @doc "Получить значение; при отсутствии — raise."
      @spec get!(Context.t()) :: unquote(context_accessor_value)

      def get!(%Context{} = context), do: Context.get!(context, @context_accessor_key)

      if is_nil(context_accessor_type) do
        @doc "Записать значение по ключу."
        @spec put(Context.t(), term()) :: Context.t()

        def put(%Context{} = context, value),
          do: Context.put(context, @context_accessor_key, value)
      else
        @doc "Записать значение по ключу."
        @spec put(Context.t(), unquote(context_accessor_type).t()) :: Context.t()

        def put(%Context{} = context, %unquote(context_accessor_type){} = value),
          do: Context.put(context, @context_accessor_key, value)
      end

      @doc "Удалить значение по ключу."
      @spec delete(Context.t()) :: Context.t()

      def delete(%Context{} = context), do: Context.delete(context, @context_accessor_key)

      defoverridable exists?: 1, find: 1, get: 1, get!: 1, put: 2, delete: 1
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys
end
