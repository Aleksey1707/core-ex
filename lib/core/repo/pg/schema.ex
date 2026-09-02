defmodule Core.Repo.Pg.Schema do
  @moduledoc """
  Билдер производных функций Ecto-схемы репозитория.

      schema "roles" do
        # ...
      end

      use Core.Repo.Pg.Schema,
        entity: MyApp.Domain.<BC>.Common.Role,
        id: MyApp.Domain.<BC>.Common.Role.ID

  Ставится **после** блока `schema/2` (нужен `defstruct`); safe-мапперы схема пишет сама —
  они и есть источник истины (см. `13-repos.md`).

  ## Режимы

  | Режим | Схема | Генерируется | Пишется руками |
  |---|---|---|---|
  | `entity:` | write-репозитория | `@type t`, `to_entity!/1`, `to_model!/1`, `dump_id/1` | `to_entity/1`, `to_model/1` |
  | `view:` | read-репозитория | `@type t`, `dump_id/1` | `to_view/1` |

  `to_view/1` **тотален**: представление собирается из примитивных значений строки, доменной
  валидации на read-пути нет — значит нет и `{:error, _}`, который разворачивала бы bang-обёртка.
  Его наличие проверяется после компиляции схемы.

  ## Opts

  - `entity:` — модуль доменной сущности (взаимоисключение с `view:`)
  - `view:` — модуль представления read-репозитория (взаимоисключение с `entity:`)
  - `id:` — Prim идентификатора сущности (не обязан быть `<entity>.ID`)
  - `codec:` — entity-фасад Codec; по умолчанию резолвится в рантайме
    через `Core.Config.codec()`
  """

  alias Core.Helper

  @label "Repo.Pg.Schema"
  @required_keys ~w(id)a
  @optional_keys ~w(entity view codec)a

  @doc "Объявить производные функции Ecto-схемы репозитория."
  defmacro __using__(opts) do
    cfg =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    {:__block__, [], parts(cfg)}
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec after_compile!(Macro.Env.t(), binary()) :: :ok

  def after_compile!(env, _bytecode) do
    mod = env.module

    unless Module.defines?(mod, {:to_view, 1}) do
      raise CompileError,
        description: "#{@label}: #{inspect(mod)} с view: должен объявить to_view/1",
        file: env.file,
        line: env.line
    end

    :ok
  end

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    {mode, item} = mode!(opts)

    %{
      mode: mode,
      item: item,
      id: Helper.Opts.module!(opts, :id, @label, exports: [new: 1]),
      codec: codec!(opts)
    }
  end

  # Без явного `codec:` фасад резолвится в рантайме, а не запекается макросом:
  # библиотека компилируется раньше конфигурации приложения (и раньше `runtime.exs`),
  # поэтому требовать `Config.codec()` на этапе компиляции нельзя.
  defp codec!(opts) do
    case Keyword.get(opts, :codec) do
      nil -> quote(do: Core.Config.codec())
      _module -> Helper.Opts.module!(opts, :codec, @label)
    end
  end

  defp mode!(opts) do
    opts
    |> Keyword.take(~w(entity view)a)
    |> Keyword.keys()
    |> Enum.uniq()
    |> mode(opts)
  end

  defp mode([:entity], opts), do: {:entity, Helper.Opts.module!(opts, :entity, @label)}

  defp mode([:view], opts), do: {:view, Helper.Opts.module!(opts, :view, @label)}

  defp mode([], _opts) do
    raise CompileError,
      description: "#{@label}: missing required option(s): [:entity] или [:view]"
  end

  defp mode(_entity_and_view, _opts) do
    raise CompileError,
      description: "#{@label}: entity: и view: взаимоисключающие (write — агрегат, read — View)"
  end

  defp parts(%{mode: :entity} = cfg) do
    [type_t(), to_entity_bang(cfg), to_model_bang(cfg), dump_id(cfg)]
  end

  defp parts(%{mode: :view} = cfg) do
    [after_compile_hook(), type_t(), dump_id(cfg)]
  end

  defp after_compile_hook do
    quote do
      @after_compile {Core.Repo.Pg.Schema, :after_compile!}
    end
  end

  defp type_t do
    quote do
      @type t :: %__MODULE__{}
    end
  end

  defp to_entity_bang(cfg) do
    quote do
      @doc "Строка БД → доменная сущность; при ошибке — raise."
      @spec to_entity!(t()) :: unquote(cfg.item).t()

      def to_entity!(%__MODULE__{} = row), do: Core.Result.unwrap!(to_entity(row))
    end
  end

  defp to_model_bang(cfg) do
    quote do
      @doc "Доменная сущность → map для changeset; при ошибке — raise."
      @spec to_model!(unquote(cfg.item).t()) :: map()

      def to_model!(%unquote(cfg.item){} = entity),
        do: Core.Result.unwrap!(to_model(entity))
    end
  end

  defp dump_id(cfg) do
    quote do
      @doc "Доменный ID → значение для колонки binary_id."
      @spec dump_id(unquote(cfg.id).t()) :: String.t()

      def dump_id(%unquote(cfg.id){} = id), do: unquote(cfg.codec).dump(id)
    end
  end
end
