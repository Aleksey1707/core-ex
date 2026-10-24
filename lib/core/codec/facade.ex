defmodule Core.Codec.Facade do
  @moduledoc """
  Билдер entity-фасада: плагины + делегирование Prim-профилю.

  ```elixir
  use Core.Codec.Facade,
    prim: MyApp.Codec.Prim.Internal,
    plugins: [MyApp.Domain.<BC>.<Aggregate>.Codec]
  ```

  Наружу фасад отдаёт три функции — `dump/1`, `load/2`, `load!/2`
  (`Core.Codec.Facade.Behaviour`). Значение без плагина уходит в Prim-профиль.

  Служебная `__codec_redump__/1` отдаёт `Core.Codec.Redump` спеку пере-дампа типа по ссылке
  `{:codec, Type}`: её выводит или объявляет колбэком `redump_spec/1` плагин типа. Тип плагина без
  спеки (ручной без клаузы колбэка) и модуль без плагина — `ArgumentError`, где названы тип и плагин
  (фасад); бросает его сам фасад, не вызывая плагин (`__codec_redump_missing__/0`). Фасад без единого
  типа со спекой объявляет `__codec_redump__/1` как `no_return()`.

  ## Семейства типов

  Плагин с `union:` получает клоузу `load/2` на сам модуль-семейство: `codec.load(<Aggregate>.Event,
  data)` возвращает то событие, тег которого лежит в данных. Выбор конкретного типа — задача
  плагина, фасад про теги не знает: модули типов и семейств обязаны быть уникальными между
  плагинами, и это проверяется на компиляции.

  Свои проверки плагин делает сам: фасад при сборке отдаёт каждому плагину полный список
  `plugins:` (`__codec_check__/1`, `Core.Codec.Plugin`), отказ — `CompileError`. Так кодек событий
  сверяет уникальность типа агрегата и то, что его нагрузку-сущность обслуживает плагин того же
  фасада. Плагинов сверх `plugins:` фасад не добавляет.

  ## Сужение результата

  Клоузы плагинов сужают его результат паттерном, который отдаёт сам плагин (`__codec_pattern__/1`,
  по умолчанию `%Type{}`), и компилятор у вызывающего знает тип значения:
  `load(A, raw)` — `{:ok, %A{}} | {:error, _}`, `load(<Aggregate>.Event, raw)` — объединение
  `{:ok, %Event.X{}}` по событиям кодека, `load!/2` — само значение, ошибка плагина — `raise Core.Exc`.
  Событие сужается и по нагрузке: `%Event.X{payload: %Payload{}}` либо `payload: nil`. Опечатка в
  поле загруженного значения или его нагрузки и невозможная clause по результату — предупреждение при
  сборке вызывающего.

  Фолбэк `dump/1` принимает только struct с полем `value` (`Core.Guard.is_prim/1`): команда или View
  без плагина — предупреждение при сборке, при исполнении — `FunctionClauseError`; struct с полем
  `value`, который не Prim, — `ArgumentError`. Фолбэк `load/2` / `load!/2` по атому не сужен: Prim по
  атому в guard не распознать, и модуль без плагина компилятор не ловит.

  ## Опции

  `plugins:` — опция-выражение (`docs/rules/20-agreements.md`, «Опции `use`»): список вычисляется в
  теле фасада, поэтому законны `<App>.Codec.plugins()` и атрибут; не список — `CompileError`
  «Codec.Facade: plugins: ожидается список модулей». `prim:` — литерал, модуль профиля проверяется
  при раскрытии `use` и MUST NOT быть вложен в фасад.
  """

  alias Core.Helper
  alias Core.Prim

  @label "Codec.Facade"
  @required_keys ~w(prim)a
  @optional_keys ~w(plugins)a
  @expression_keys ~w(plugins)a

  # ===== билдер =====

  @doc "Объявить entity-фасад (`prim:` + `plugins:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    prim = Helper.Opts.module!(opts, :prim, @label, exports: [dump: 1, load: 2, load!: 2])

    [
      quote do
        @behaviour Core.Codec.Facade.Behaviour

        @prim unquote(prim)
        @plugins Core.Codec.Facade.plugins!(unquote(Keyword.get(opts, :plugins, [])))

        Core.Codec.Facade.validate_mods!(@plugins)
        Core.Codec.Facade.check_plugins!(@plugins)
      end,
      quote unquote: false do
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
        @spec load(module(), term()) :: Core.Result.t()

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

        @doc false
        if Core.Codec.Facade.redump?(@plugins),
          do: @spec(__codec_redump__(module()) :: Core.Codec.Redump.spec()),
          else: @spec(__codec_redump__(module()) :: no_return())

        @impl true
        for plugin <- @plugins,
            missing = plugin.__codec_redump_missing__(),
            mod <- Core.Codec.Facade.load_mods(plugin),
            not List.keymember?(missing, mod, 0) do
          def __codec_redump__(unquote(mod)), do: unquote(plugin).__codec_redump__(unquote(mod))
        end

        for plugin <- @plugins,
            {mod, culprit} <- plugin.__codec_redump_missing__() do
          def __codec_redump__(unquote(mod)), do: Core.Codec.Plugin.Redump.missing!(unquote(culprit), unquote(plugin))
        end

        def __codec_redump__(mod) when is_atom(mod) do
          raise ArgumentError, "#{inspect(mod)}: нет codec-плагина в фасаде #{inspect(__MODULE__)} — спеки redump нет"
        end
      end
    ]
  end

  @doc false
  @spec plugins!(term()) :: [module()]

  def plugins!(plugins) when is_list(plugins), do: plugins

  def plugins!(other),
    do: Helper.Opts.reject!("#{@label}: plugins", "ожидается список модулей, получено #{inspect(other)}")

  @doc """
  Есть ли у плагинов фасада хоть один тип со спекой пере-дампа.

  Без него каждая клауза `__codec_redump__/1` фасада бросает, и `@spec` со спекой разошёлся бы с
  success typing `none()` у Dialyzer.
  """
  @spec redump?([module()]) :: boolean()

  def redump?(plugins) when is_list(plugins) do
    Enum.any?(plugins, fn plugin ->
      missing = plugin.__codec_redump_missing__()

      Enum.any?(load_mods(plugin), &(not List.keymember?(missing, &1, 0)))
    end)
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
        Helper.Opts.reject!(
          "#{@label}: plugins",
          "тип #{inspect(mod)} объявлен дважды: в #{inspect(plugin)} и #{inspect(other)}"
        )

      :error ->
        Map.put(acc, mod, plugin)
    end
  end

  # ===== сужение load =====

  @doc false
  @spec load_clauses(module(), module(), :load | :load!) :: [Macro.t()]

  def load_clauses(plugin, mod, fun) when is_atom(plugin) and is_atom(mod) and fun in [:load, :load!] do
    types = if mod == plugin.__codec_union__(), do: plugin.__codec_types__(), else: [mod]
    patterns = Enum.map(types, &plugin.__codec_pattern__/1)

    Enum.flat_map(patterns, &ok_clause(&1, fun)) ++ error_clause(fun)
  end

  # ---

  defp ok_clause(pattern, :load), do: quote(generated: true, do: ({:ok, unquote(pattern) = value} -> {:ok, value}))
  defp ok_clause(pattern, :load!), do: quote(generated: true, do: ({:ok, unquote(pattern) = value} -> value))

  defp error_clause(:load), do: quote(generated: true, do: ({:error, reason} -> {:error, reason}))
  defp error_clause(:load!), do: quote(generated: true, do: ({:error, %Core.Error{} = error} -> raise Core.Exc, error))

  # ===== проверки плагинов =====

  @doc """
  Проверки плагинов против полного списка `plugins:` (compile-time).

  Что проверять, знает плагин (`__codec_check__/1`): у кодека событий — уникальность типа
  агрегата и обслуживание нагрузок-сущностей, у прочих по умолчанию нечего. Отказ — `CompileError`.
  """
  @spec check_plugins!([module()]) :: :ok

  def check_plugins!(plugins) when is_list(plugins) do
    plugins
    |> ensure_plugins!()
    |> Enum.each(&(:ok = &1.__codec_check__(plugins)))
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

    if not Helper.Module.exports?(plugin, :__codec_types__, 0) do
      Helper.Opts.reject!("#{@label}: plugins", "плагин #{inspect(plugin)} должен реализовывать Codec.Plugin")
    end
  end

  defp ensure_plugin!(plugin),
    do: Helper.Opts.reject!("#{@label}: plugins", "ожидается модуль, получено #{inspect(plugin)}")
end
