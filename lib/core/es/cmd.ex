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

  Уничтожаемое поле (`destroyable: true`) у команды по полям — `CompileError` с путём до поля:
  уничтоженное ПДн-значение не записывается, и тип команды его не допускает. Проверяются поля
  команды, элементы `list:` / `set:` и значения `map:` и поля сущностей `entity:`, собранных
  `Core.Struct`, на любой глубине; варианты `union:` и ручной struct не обходятся (ADR-0092).

  Опций нет.
  """

  alias Core.Codec.Field
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
        reject_destroyable!(env)
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
    if Field.struct_fields(module), do: "полями без default:", else: "в @enforce_keys"
  end

  defp reject_destroyable!(env) do
    case destroyable_places(env.module, Field.struct_fields(env.module) || [], []) do
      [] ->
        :ok

      [{owner, path} | _rest] ->
        raise CompileError,
          description:
            "#{@label}: #{inspect(env.module)}: #{Enum.join(path, ": ")}: destroyable: " <>
              "#{owner_text(env.module, owner)} нет — уничтоженное ПДн-значение не записывается",
          file: env.file,
          line: env.line
    end
  end

  # Места `destroyable:` полей модуля и полей сущностей `entity:` в их значениях на любой глубине:
  # `[{модуль поля, путь}]`. Ручной struct сущности и варианты `union:` не обходятся.
  defp destroyable_places(module, fields, prefix) do
    Enum.flat_map(fields, fn %Field{name: name, spec: spec, destroyable: places} ->
      path = prefix ++ [name]

      for(place <- places, do: {module, path ++ Enum.map(place, &step_text/1)}) ++ entity_places(spec, path)
    end)
  end

  defp entity_places({:entity, module}, path) do
    case Field.struct_fields(module) do
      nil -> []
      fields -> destroyable_places(module, fields, path)
    end
  end

  defp entity_places(spec, path),
    do: Enum.flat_map(Field.values(spec), &entity_places(&1, path ++ [step_text(spec_step(spec))]))

  defp spec_step({:map, _key, _value}), do: :value
  defp spec_step({kind, _inner}), do: kind

  # Шаг пути — как в отказах `Core.Struct`: значение словаря — `map: value`.
  defp step_text(:value), do: "map: value"
  defp step_text(kind), do: Atom.to_string(kind)

  defp owner_text(module, module), do: "у команды"
  defp owner_text(_module, owner), do: "у сущности #{inspect(owner)} в команде"
end
