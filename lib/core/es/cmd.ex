defmodule Core.Es.Cmd do
  @moduledoc """
  Builder команды event-sourced агрегата (`<Aggregate>.Cmd.<Name>`).

      defmodule MyApp.Domain.<BC>.Account.Cmd.Rename do
        use Core.Es.Cmd

        use Core.Struct,
          fields: [
            name: [prim: MyApp.Domain.<BC>.Account.Name],
            at: [prim: Core.Es.Event.At],
            by: [prim: MyApp.Domain.<BC>.Values.UserID]
          ]
      end

  Команда — struct из Prim, собирает её usecase. Автор и момент событий приходят из
  команды, а не из `Context` и не из часов библиотеки: `by` — Prim автора событий агрегата,
  `at` — `%Core.Es.Event.At{}`. Оба поля MUST быть в `@enforce_keys` — иначе `CompileError`: у
  структуры по полям (`use Core.Struct`) это поля без `default:`, ручной struct перечисляет их
  сам (`@enforce_keys ~w(name at by)a` + `defstruct @enforce_keys`). Типы значений проверяет
  конструктор события при исполнении команды (`Core.Es.Aggregate`).

  Опций нет.
  """

  alias Core.Helper

  @label "Es.Cmd"
  @required_keys ~w()a
  @optional_keys ~w()a
  @expression_keys ~w()a
  @stamp_keys ~w(by at)a

  @doc "Объявить команду event-sourced агрегата."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    Helper.Opts.literal!(opts, @expression_keys, @label)

    quote do
      @after_compile Core.Es.Cmd
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
            "#{@label}: #{inspect(env.module)} обязан объявить #{inspect(@stamp_keys)} " <>
              "#{stamp_hint(env.module)} — автор и момент событий приходят из команды; нет #{inspect(missing)}",
          file: env.file,
          line: env.line
    end
  end

  defp stamp_hint(module) do
    if Core.Codec.Field.struct_fields(module), do: "полями без default:", else: "в @enforce_keys"
  end
end
