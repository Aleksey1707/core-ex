defmodule Core.Codec.Facade do
  @moduledoc """
  Билдер entity-фасада: плагины + делегирование Prim-профилю.

  ```elixir
  use Core.Codec.Facade,
    prim: MyApp.Codec.Prim.Internal,
    plugins: [MyApp.Domain.Foo.Codec]
  ```
  """

  alias Core.Error
  alias Core.Helper
  alias Core.Prim

  require Error

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
      @tag_to_plugin Core.Codec.Facade.build_tag_map!(@plugins)

      @doc "Модуль Prim-кодека этого фасада."
      @spec prim() :: module()

      @impl true
      def prim, do: @prim

      @doc "Dump raw-значения по kind: делегат в Prim-профиль фасада."
      @spec dump_raw(atom(), term()) :: term()

      @impl true
      def dump_raw(kind, value) when is_atom(kind), do: @prim.dump_raw(kind, value)

      @doc "Dump raw-значения в формате Prim `mod`: делегат в Prim-профиль фасада."
      @spec dump_raw_as(module(), term()) :: term()

      @impl true
      def dump_raw_as(mod, value) when is_atom(mod), do: @prim.dump_raw_as(mod, value)

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
          type <- plugin.__codec_types__() do
        def load(unquote(type), raw) do
          unquote(plugin).load(unquote(type), raw, __MODULE__)
        end
      end

      # Тип dump-only плагина (`loadable: false`) load-клоуза не получает и без этой
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

      @doc """
      Domain → `{wire_tag, payload}` для tagged-плагинов.

      Обратная операция к `load_tagged/2`: тег берётся у плагина, объявившего тип,
      payload — его же `dump/2`.
      """
      @spec dump_tagged(struct()) :: {term(), term()}

      @impl true
      def dump_tagged(%mod{} = value) do
        Core.Codec.Facade.tagged_pair(@tag_to_plugin, mod, value, __MODULE__)
      end

      @doc "Tagged wire → domain через плагины с `load_tagged/3`."
      @spec load_tagged(term(), term()) :: {:ok, term()} | {:error, Error.t()}

      @impl true
      def load_tagged(type, payload) do
        Core.Codec.Facade.dispatch_tagged(
          @tag_to_plugin,
          type,
          payload,
          __MODULE__
        )
      end

      @doc "Tagged wire → domain; при ошибке — raise."
      @spec load_tagged!(term(), term()) :: term()

      @impl true
      def load_tagged!(type, payload) do
        Core.Result.unwrap!(load_tagged(type, payload))
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
      @spec load(module(), term()) :: {:ok, term()} | {:error, Error.t()}

      @impl true
      def load(mod, raw) when is_atom(mod) do
        if Prim.prim?(mod),
          do: @prim.load(mod, raw),
          else: raise(ArgumentError, "нет codec-плагина для #{inspect(mod)}")
      end

      @doc "Load bang через `load/2` (плагин или Prim)."
      @spec load!(module(), term()) :: term()

      @impl true
      def load!(mod, raw) when is_atom(mod) do
        Core.Result.unwrap!(load(mod, raw))
      end
    end
  end

  @doc false
  @spec build_type_map!([module()]) :: %{optional(module()) => module()}

  def build_type_map!(plugins) when is_list(plugins) do
    plugins
    |> ensure_plugins!()
    |> Enum.reduce(%{}, &merge_plugin_types!/2)
  end

  @doc false
  @spec build_tag_map!([module()]) :: %{optional(String.t()) => module()}

  def build_tag_map!(plugins) when is_list(plugins) do
    plugins
    |> Enum.filter(& &1.__codec_tagged__())
    |> Enum.reduce(%{}, &merge_plugin_tags!/2)
  end

  @doc """
  Domain-struct → `{wire_tag, payload}` через плагин, объявивший тип.

  Модуль без tagged-плагина — `ArgumentError`: тега для него не существует.
  """
  @spec tagged_pair(map(), module(), struct(), module()) :: {term(), term()}

  def tagged_pair(tag_to_plugin, mod, value, codec) when is_map(tag_to_plugin) do
    case Enum.find(tag_to_plugin, fn {_tag, plugin} -> plugin.fetch_type(mod) != :error end) do
      {_tag, plugin} ->
        {:ok, tag} = plugin.fetch_type(mod)
        {tag, plugin.dump(value, codec)}

      nil ->
        raise ArgumentError, "нет tagged-плагина для #{inspect(mod)}"
    end
  end

  @doc false
  @spec dispatch_tagged(%{optional(String.t()) => module()}, term(), term(), module()) ::
          {:ok, term()} | {:error, Error.t()}

  def dispatch_tagged(tag_to_plugin, type, payload, codec)
      when is_map(tag_to_plugin) and is_binary(type) and is_map(payload) do
    case Map.fetch(tag_to_plugin, type) do
      {:ok, plugin} ->
        plugin.load_tagged(type, payload, codec)

      :error ->
        {:error,
         Error.domain(codec,
           code: :unknown_tagged_type,
           ns: :codec,
           message: "Неизвестный тип",
           detail: type
         )}
    end
  end

  def dispatch_tagged(_tag_to_plugin, type, payload, codec) do
    {:error,
     Error.domain(codec,
       code: :invalid_tagged_input,
       ns: :codec,
       message: "Некорректный тип операции",
       detail: {type, payload}
     )}
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

  defp merge_plugin_types!(plugin, acc) do
    Enum.reduce(plugin.__codec_types__(), acc, fn type, inner ->
      put_unique_type!(inner, type, plugin)
    end)
  end

  defp put_unique_type!(acc, type, plugin) do
    case Map.fetch(acc, type) do
      {:ok, other} ->
        raise CompileError,
          description:
            "duplicate codec type #{inspect(type)} in #{inspect(plugin)} and #{inspect(other)}"

      :error ->
        Map.put(acc, type, plugin)
    end
  end

  defp merge_plugin_tags!(plugin, acc) do
    Enum.reduce(plugin.__codec_tags__(), acc, fn tag, inner ->
      put_unique_tag!(inner, tag, plugin)
    end)
  end

  defp put_unique_tag!(acc, tag, plugin) do
    case Map.fetch(acc, tag) do
      {:ok, other} ->
        raise CompileError,
          description:
            "duplicate codec tag #{inspect(tag)} in #{inspect(plugin)} and #{inspect(other)}"

      :error ->
        Map.put(acc, tag, plugin)
    end
  end
end
