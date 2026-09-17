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
  проверяется на компиляции. Так же уникален между кодеками событий тип агрегата (`type:`).

  ## Сужение результата

  Клоузы плагинов сужают его результат паттерном, и компилятор у вызывающего знает тип значения:
  `load(A, raw)` — `{:ok, %A{}} | {:error, _}`, `load(<Aggregate>.Event, raw)` — объединение
  `{:ok, %Event.X{}}` по событиям кодека, `load!/2` — само значение, ошибка плагина — `raise Core.Exc`.
  Событие сужается и по нагрузке: `%Event.X{payload: %Payload{}}` либо `payload: nil`. Опечатка в
  поле загруженного значения или его нагрузки и невозможная clause по результату — предупреждение при
  сборке вызывающего.

  Фолбэк `dump/1` принимает только struct с полем `value` (`Core.Guard.is_prim/1`): команда или View
  без плагина — предупреждение при сборке, при исполнении — `FunctionClauseError`; struct с полем
  `value`, который не Prim, — `ArgumentError`. Фолбэк `load/2` / `load!/2` по атому не сужен: Prim по
  атому в guard не распознать, и модуль без плагина компилятор не ловит.
  """

  alias Core.Helper
  alias Core.Prim

  # ===== билдер =====

  @doc "Объявить entity-фасад (`prim:` + `plugins:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(prim)a, ~w(plugins)a, "Codec.Facade")

      @behaviour Core.Codec.Facade.Behaviour

      @prim Helper.Opts.module!(opts, :prim, "Codec.Facade", exports: [dump: 1, load: 2, load!: 2])
      @plugins Keyword.get(opts, :plugins, [])

      if not is_list(@plugins) do
        raise CompileError, description: "plugins: ожидается список модулей"
      end

      Core.Codec.Facade.validate_mods!(@plugins)
      Core.Codec.Facade.validate_es_types!(@plugins)

      require Core.Guard

      @doc "Dump: entity-плагин или Prim; struct без плагина обязан быть Prim."
      @spec dump(struct()) :: term()

      @impl true
      for plugin <- @plugins,
          type <- plugin.__codec_types__() do
        def dump(%unquote(type){} = value) do
          unquote(plugin).dump(value, __MODULE__)
        end
      end

      def dump(%mod{} = value) when Core.Guard.is_prim(value) do
        if Prim.prim?(mod),
          do: @prim.dump(value),
          else: raise(ArgumentError, "нет codec-плагина для #{inspect(mod)}")
      end

      @doc "Load: entity-плагин или Prim."
      @spec load(module(), term()) :: {:ok, term()} | {:error, Core.Error.t()}

      @impl true
      for plugin <- @plugins,
          plugin.__codec_loadable__(),
          mod <- Core.Codec.Facade.load_mods(plugin) do
        def load(unquote(mod), raw) do
          case unquote(plugin).load(unquote(mod), raw, __MODULE__) do
            unquote(Core.Codec.Facade.load_clauses(plugin, mod, :load))
          end
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

      def load(mod, raw) when is_atom(mod) do
        if Prim.prim?(mod),
          do: @prim.load(mod, raw),
          else: raise(ArgumentError, "нет codec-плагина для #{inspect(mod)}")
      end

      @doc "Load через `load/2`; при ошибке — raise."
      @spec load!(module(), term()) :: term()

      @impl true
      for plugin <- @plugins,
          plugin.__codec_loadable__(),
          mod <- Core.Codec.Facade.load_mods(plugin) do
        def load!(unquote(mod), raw) do
          case unquote(plugin).load(unquote(mod), raw, __MODULE__) do
            unquote(Core.Codec.Facade.load_clauses(plugin, mod, :load!))
          end
        end
      end

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
  Проверить модули типов и семейств всех плагинов (compile-time).

  Модуль — единственный ключ диспетчеризации фасада, поэтому он обязан быть уникальным:
  дубль между плагинами — `CompileError`.
  """
  @spec validate_mods!([module()]) :: :ok

  def validate_mods!(plugins) when is_list(plugins) do
    _by_mod =
      plugins
      |> ensure_plugins!()
      |> Enum.reduce(%{}, &merge_plugin_mods!/2)

    :ok
  end

  # ---

  defp merge_plugin_mods!(plugin, acc) do
    Enum.reduce(load_mods(plugin), acc, fn mod, inner ->
      put_unique_mod!(inner, mod, plugin)
    end)
  end

  defp put_unique_mod!(acc, mod, plugin) do
    case Map.fetch(acc, mod) do
      {:ok, other} ->
        raise CompileError,
          description: "тип #{inspect(mod)} объявлен дважды: в #{inspect(plugin)} и #{inspect(other)}"

      :error ->
        Map.put(acc, mod, plugin)
    end
  end

  # ===== сужение load =====

  @doc false
  @spec load_clauses(module(), module(), :load | :load!) :: [Macro.t()]

  def load_clauses(plugin, mod, fun) when is_atom(plugin) and is_atom(mod) and fun in [:load, :load!] do
    types = if mod == plugin.__codec_union__(), do: plugin.__codec_types__(), else: [mod]
    patterns = Enum.map(types, &type_pattern(plugin, &1))

    Enum.flat_map(patterns, &ok_clause(&1, fun)) ++ error_clause(fun)
  end

  # ---

  # Поля struct компилятор не типизирует, поэтому событие сужается ещё и по нагрузке: иначе опечатка
  # в её поле после `load/2` молчала бы.
  defp type_pattern(plugin, type) do
    if function_exported?(plugin, :__es_type__, 0),
      do: Core.Es.Check.event_pattern(type),
      else: quote(do: %unquote(type){})
  end

  defp ok_clause(pattern, :load), do: quote(generated: true, do: ({:ok, unquote(pattern) = value} -> {:ok, value}))
  defp ok_clause(pattern, :load!), do: quote(generated: true, do: ({:ok, unquote(pattern) = value} -> value))

  defp error_clause(:load), do: quote(generated: true, do: ({:error, reason} -> {:error, reason}))
  defp error_clause(:load!), do: quote(generated: true, do: ({:error, %Core.Error{} = error} -> raise Core.Exc, error))

  # ===== типы агрегата =====

  @doc """
  Проверить типы агрегата кодеков событий среди плагинов (compile-time).

  Тип агрегата (`type:` у `Core.Es.Event.Codec`) — первая часть адреса потока событий, поэтому
  два кодека с одним типом в одном фасаде — `CompileError`.
  """
  @spec validate_es_types!([module()]) :: :ok

  def validate_es_types!(plugins) when is_list(plugins) do
    _by_type =
      plugins
      |> ensure_plugins!()
      |> Enum.filter(&function_exported?(&1, :__es_type__, 0))
      |> Enum.reduce(%{}, &put_unique_es_type!/2)

    :ok
  end

  # ---

  defp put_unique_es_type!(plugin, acc) do
    type = plugin.__es_type__()

    case Map.fetch(acc, type) do
      {:ok, other} ->
        raise CompileError,
          description: "тип агрегата #{inspect(type)} объявлен дважды: в #{inspect(plugin)} и #{inspect(other)}"

      :error ->
        Map.put(acc, type, plugin)
    end
  end

  # ===== общее =====

  defp ensure_plugins!(plugins) do
    Enum.each(plugins, &ensure_plugin!/1)

    plugins
  end

  # `ensure_compiled!` отделяет «модуль ещё не собран» от «собран, но не плагин»: без него
  # обе причины приходили бы одной `UndefinedFunctionError` на `__codec_types__/0`.
  defp ensure_plugin!(plugin) when is_atom(plugin) and not is_nil(plugin) do
    Code.ensure_compiled!(plugin)

    if not function_exported?(plugin, :__codec_types__, 0) do
      raise CompileError,
        description: "плагин #{inspect(plugin)} должен реализовывать Codec.Plugin"
    end
  end

  defp ensure_plugin!(plugin) do
    raise CompileError, description: "плагин #{inspect(plugin)}: ожидается модуль"
  end
end
