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

  Команда — вход записи: `use Core.Es.Cmd` помечает модуль до `use Core.Struct`, и `@type t`
  структуры по полям становится проекцией записи — без `Core.Es.Personal.Destroyed.t()`, даже если
  поле объявлено персональным Prim'ом; `write_t()` равен `t()`. Защиту записи даёт этот узкий тип.

  Поле с `personal: true` у команды по полям — `CompileError` с путём до поля: ПДн-место команда не
  читает. Проверяются поля команды, элементы `list:` / `set:` и значения `map:` и поля сущностей
  `entity:`, собранных `Core.Struct`, на любой глубине; варианты `union:` и ручной struct не
  обходятся. Персональные Prim без `personal: true` у команды допустимы: пишутся они открыто, а
  уничтоженного значения у типа записи нет. Поле событий `events:` (`Core.Struct`) у команды —
  `CompileError`: события порождает `decide/2` агрегата.

  Опций нет.
  """

  alias Core.Field
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
      Module.register_attribute(__MODULE__, :core_command, persist: false)
      @core_command true
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
        reject_personal!(env)
        Core.Struct.reject_events!(env, @label, "у команды нет — события порождает decide/2 агрегата")
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
    if Field.introspect(module), do: "полями без default:", else: "в @enforce_keys"
  end

  defp reject_personal!(env) do
    case Core.Field.introspect(env.module) do
      nil ->
        :ok

      fields ->
        case personal_path(env.module, fields) do
          nil ->
            :ok

          {owner, path} ->
            raise CompileError,
              description:
                "#{@label}: #{inspect(env.module)}: #{Enum.join(path, ": ")}: personal: " <>
                  "#{owner_text(env.module, owner)} нет — ПДн-место в команде не читается",
              file: env.file,
              line: env.line
        end
    end
  end

  defp personal_path(module, fields) do
    case Enum.find(Core.Field.personal_places(fields, [], key: :name), &explicit_place?(fields, &1.path)) do
      nil -> nil
      %{path: path} -> place(module, fields, path, [])
    end
  end

  # Команда отвергает явную ПДн-границу (`personal: true` у поля или вложенного вида), а не Prim,
  # который персональный сам по себе: его значение в команде читается открытым.
  defp explicit_place?(fields, [name | rest]) do
    case Enum.find(fields, &(&1.name == name)) do
      %Core.Field{personal: true} -> true
      %Core.Field{spec: spec} -> spec_place?(spec, rest)
    end
  end

  defp spec_place?({:personal, _inner}, _rest), do: true
  defp spec_place?({:personal_false, inner}, rest), do: spec_place?(inner, rest)
  defp spec_place?({kind, inner}, [:each | rest]) when kind in ~w(list set)a, do: spec_place?(inner, rest)

  defp spec_place?({:entity, module}, rest) do
    case Core.Field.introspect(module) do
      nil -> false
      fields -> explicit_place?(fields, rest)
    end
  end

  defp spec_place?({:map, _key, value}, [:each | rest]), do: spec_place?(value, rest)
  defp spec_place?(_spec, _rest), do: false

  # Владелец места — модуль, в чьей декларации поле стало ПДн-местом; путь — имена полей, а
  # контейнер назван видом (`list`, `set`, `map: value`).
  defp place(module, _fields, [], text), do: {module, Enum.reverse(text)}

  defp place(module, fields, [name | rest], text) when is_atom(name) and name != :each do
    %Core.Field{spec: spec} = Enum.find(fields, &(&1.name == name))
    text = [Atom.to_string(name) | text]

    if rest == [], do: {module, Enum.reverse(text)}, else: place_in(module, spec, rest, text)
  end

  defp place_in(module, {:entity, _entity}, [], text), do: {module, Enum.reverse(text)}
  defp place_in(_module, {:entity, entity}, rest, text), do: place(entity, Core.Field.introspect(entity), rest, text)
  defp place_in(module, {:personal_false, inner}, rest, text), do: place_in(module, inner, rest, text)
  defp place_in(module, {:personal, inner}, rest, text), do: place_in(module, inner, rest, text)

  defp place_in(module, {kind, _inner}, [:each], text) when kind in ~w(list set)a,
    do: {module, Enum.reverse([kind | text])}

  defp place_in(module, {:list, inner}, [:each | rest], text), do: place_in(module, inner, rest, ["list" | text])
  defp place_in(module, {:set, inner}, [:each | rest], text), do: place_in(module, inner, rest, ["set" | text])

  defp place_in(module, {:map, _key, _value}, [:each], text),
    do: {module, Enum.reverse(["map: value" | text])}

  defp place_in(module, {:map, _key, value}, [:each | rest], text),
    do: place_in(module, value, rest, ["map: value" | text])

  defp place_in(module, _spec, _rest, text), do: {module, Enum.reverse(text)}

  defp owner_text(module, module), do: "у команды"
  defp owner_text(_module, owner), do: "у сущности #{inspect(owner)} в команде"
end
