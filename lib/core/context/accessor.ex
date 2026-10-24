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

  ## Опции

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов
  функции в опции — `CompileError` «ожидается литерал». Модуль `type:` проверяется при раскрытии
  и MUST NOT быть вложен в вызывающего.
  """

  alias Core.Helper

  @label "Context.Accessor"
  @required_keys ~w(key)a
  @optional_keys ~w(type)a
  @expression_keys ~w()a

  @doc "Типизированный accessor ключа Context (`key:` + опциональный `type:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    key = Helper.Opts.atom!(opts, :key, @label)
    type = if Keyword.has_key?(opts, :type), do: Helper.Opts.module!(opts, :type, @label)
    value = if is_nil(type), do: quote(do: term()), else: quote(do: unquote(type).t())

    quote do
      alias Core.Context
      alias Core.Error

      @context_accessor_key unquote(key)

      @doc "Есть ли значение по ключу."
      @spec exists?(Context.t()) :: boolean()

      def exists?(%Context{} = context), do: Context.exists?(context, @context_accessor_key)

      @doc "Найти значение или `nil`."
      @spec find(Context.t()) :: unquote(value) | nil

      def find(%Context{} = context), do: Context.find(context, @context_accessor_key)

      @doc "Получить значение; при отсутствии — ошибка."
      @spec get(Context.t()) :: Core.Result.t(unquote(value))

      def get(%Context{} = context), do: Context.get(context, @context_accessor_key)

      @doc "Получить значение; при отсутствии — raise."
      @spec get!(Context.t()) :: unquote(value)

      def get!(%Context{} = context), do: Context.get!(context, @context_accessor_key)

      unquote(put_function(type))

      @doc "Удалить значение по ключу."
      @spec delete(Context.t()) :: Context.t()

      def delete(%Context{} = context), do: Context.delete(context, @context_accessor_key)

      defoverridable exists?: 1, find: 1, get: 1, get!: 1, put: 2, delete: 1
    end
  end

  # ---

  defp put_function(nil) do
    quote do
      @doc "Записать значение по ключу."
      @spec put(Context.t(), term()) :: Context.t()

      def put(%Context{} = context, value),
        do: Context.put(context, @context_accessor_key, value)
    end
  end

  defp put_function(type) do
    quote do
      @doc "Записать значение по ключу."
      @spec put(Context.t(), unquote(type).t()) :: Context.t()

      def put(%Context{} = context, %unquote(type){} = value),
        do: Context.put(context, @context_accessor_key, value)
    end
  end
end
