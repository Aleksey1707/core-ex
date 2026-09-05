defmodule Core.Codec.Facade do
  @moduledoc """
  Билдер entity-фасада: плагины + делегирование Prim-профилю.

  ```elixir
  use Core.Codec.Facade,
    prim: MyApp.Codec.Prim.Internal,
    plugins: [MyApp.Domain.Foo.Codec]
  ```

  Наружу фасад отдаёт три функции — `dump/1`, `load/2`, `load!/2`
  (`Core.Codec.Facade.Behaviour`). Значение без плагина уходит в Prim-профиль.

  ## Семейства типов

  Плагин с `union:` (образец — `Core.Es.Event.Codec`) получает клоузу `load/2` на сам
  модуль-семейство: `codec.load(<Aggregate>.Event, data)` возвращает то событие, тег
  которого лежит в данных. Выбор конкретного типа — задача плагина, фасад про теги
  не знает: модули типов и семейств обязаны быть уникальными между плагинами, и это
  проверяется на компиляции.
  """

  alias Core.Helper
  alias Core.Prim

  @doc "Объявить entity-фасад (`prim:` + `plugins:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(prim)a, ~w(plugins)a, "Codec.Facade")

      @behaviour Core.Codec.Facade.Behaviour

      @prim Keyword.fetch!(opts, :prim)
      @plugins Keyword.get(opts, :plugins, [])

      if not is_atom(@prim) do
        raise CompileError, description: "prim: must be a module"
      end

      if not is_list(@plugins) do
        raise CompileError, description: "plugins: must be a list of modules"
      end

      _ = Core.Codec.Facade.build_type_map!(@plugins)

      @doc "Dump: entity-плагин или Prim."
      for plugin <- @plugins,
          type <- plugin.__codec_types__() do
        def dump(%unquote(type){} = value) do
          unquote(plugin).dump(value, __MODULE__)
        end
      end

      @doc "Load: entity-плагин или Prim."
      for plugin <- @plugins,
          plugin.__codec_loadable__(),
          mod <- Core.Codec.Facade.load_mods(plugin) do
        def load(unquote(mod), raw) do
          unquote(plugin).load(unquote(mod), raw, __MODULE__)
        end
      end

      # Тип dump-only плагина (`loadable: false`) load-клоузы не получает и без этой
      # ветки уходил бы в Prim-фолбэк, падая `UndefinedFunctionError` на
      # `__domain_kind__/0`, которого у entity нет.
      for plugin <- @plugins,
          not plugin.__codec_loadable__(),
          type <- plugin.__codec_types__() do
        def load(unquote(type), _raw) do
          raise ArgumentError,
                "#{inspect(unquote(plugin))} — dump-only плагин: " <>
                  "#{inspect(unquote(type))} через load/2 не восстанавливается"
        end
      end

      @doc "Dump: fallback на Prim или ArgumentError."
      @spec dump(struct()) :: term()

      @impl true
      def dump(%mod{} = value) do
        if Prim.prim?(mod),
          do: @prim.dump(value),
          else: raise(ArgumentError, "нет codec-плагина для #{inspect(mod)}")
      end

      @doc "Load: fallback на Prim."
      @spec load(module(), term()) :: {:ok, term()} | {:error, Core.Error.t()}

      @impl true
      def load(mod, raw) when is_atom(mod) do
        if Prim.prim?(mod),
          do: @prim.load(mod, raw),
          else: raise(ArgumentError, "нет codec-плагина для #{inspect(mod)}")
      end

      @doc "Load через `load/2`; при ошибке — raise."
      @spec load!(module(), term()) :: term()

      @impl true
      def load!(mod, raw) when is_atom(mod) do
        Core.Result.unwrap!(load(mod, raw))
      end
    end
  end

  @doc """
  Модули, на которые плагин принимает `load/3`: его типы плюс семейство (`union:`).

  Семейство не является struct-типом (`dump/1` его не знает), но в `load/2` — такой же
  ключ выбора плагина, как и обычный тип.
  """
  @spec load_mods(module()) :: [module()]

  def load_mods(plugin) when is_atom(plugin) do
    case plugin.__codec_union__() do
      nil -> plugin.__codec_types__()
      union -> [union | plugin.__codec_types__()]
    end
  end

  @doc """
  Реестр `модуль => плагин` по типам и семействам всех плагинов.

  Модуль — единственный ключ диспетчеризации фасада, поэтому он обязан быть уникальным:
  дубль между плагинами — `CompileError`.
  """
  @spec build_type_map!([module()]) :: %{optional(module()) => module()}

  def build_type_map!(plugins) when is_list(plugins) do
    plugins
    |> ensure_plugins!()
    |> Enum.reduce(%{}, &merge_plugin_mods!/2)
  end

  # ---

  defp ensure_plugins!(plugins) do
    Enum.each(plugins, fn plugin ->
      if not is_atom(plugin) do
        raise CompileError, description: "plugin #{inspect(plugin)} must be a module"
      end

      try do
        _ = plugin.__codec_types__()
      rescue
        UndefinedFunctionError ->
          reraise CompileError,
                  [description: "plugin #{inspect(plugin)} must implement Codec.Plugin"],
                  __STACKTRACE__
      end
    end)

    plugins
  end

  defp merge_plugin_mods!(plugin, acc) do
    Enum.reduce(load_mods(plugin), acc, fn mod, inner ->
      put_unique_mod!(inner, mod, plugin)
    end)
  end

  defp put_unique_mod!(acc, mod, plugin) do
    case Map.fetch(acc, mod) do
      {:ok, other} ->
        raise CompileError,
          description:
            "duplicate codec type #{inspect(mod)} in #{inspect(plugin)} and #{inspect(other)}"

      :error ->
        Map.put(acc, mod, plugin)
    end
  end
end
