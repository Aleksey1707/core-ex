defmodule Core.Es.Cmd do
  @moduledoc """
  Builder команды event-sourced агрегата (`<Aggregate>.Cmd.<Name>`).

      defmodule MyApp.Domain.<BC>.Common.Account.Cmd.Rename do
        use Core.Es.Cmd

        @enforce_keys ~w(name by at)a
        defstruct @enforce_keys
      end

  Команда — struct из Prim, собирает её usecase. Автор и момент событий приходят из
  команды, а не из `Context` и не из часов библиотеки: `by` — Prim автора событий агрегата,
  `at` — `%Core.Es.Event.At{}`. Оба поля MUST быть в `@enforce_keys` — иначе `CompileError`.
  Типы значений проверяет конструктор события при исполнении команды
  (`Core.Es.Aggregate`).

  Опций нет. Интроспекция — `__es_cmd__/0`: по ней процесс агрегата узнаёт команду.
  """

  alias Core.Helper

  @label "Es.Cmd"
  @required_keys []
  @optional_keys []
  @stamp_keys ~w(by at)a

  @doc "Объявить команду event-sourced агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)

    quote do
      @after_compile Core.Es.Cmd

      @doc false
      @spec __es_cmd__() :: true

      def __es_cmd__, do: true
    end
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok

  def __after_compile__(env, _bytecode) do
    case env.module.__info__(:struct) do
      nil ->
        raise CompileError,
          description: "#{@label}: #{inspect(env.module)} — команда — struct: нет defstruct",
          file: env.file,
          line: env.line

      fields ->
        ensure_enforced!(env, fields)
    end
  end

  # ---

  defp ensure_enforced!(env, fields) do
    enforced = for %{field: field, required: true} <- fields, do: field

    case @stamp_keys -- enforced do
      [] ->
        :ok

      missing ->
        raise CompileError,
          description:
            "#{@label}: #{inspect(env.module)} обязан объявить #{inspect(@stamp_keys)} в " <>
              "@enforce_keys — автор и момент событий приходят из команды; нет #{inspect(missing)}",
          file: env.file,
          line: env.line
    end
  end
end
