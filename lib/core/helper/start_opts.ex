defmodule Core.Helper.StartOpts do
  @moduledoc """
  Проверка опций OTP-процесса в `init/1`.

  Опции приходят из дерева супервизии потребителя и разбираются один раз: ошибка в них —
  ошибка конфигурации. `ArgumentError` в `init/1` называет опцию и ожидаемое значение,
  тогда как непроверенное значение всплывает позже и хуже: `FunctionClauseError` в
  `handle_continue/2` (супервизор уходит в цикл рестартов) или молчаливый backoff, в
  котором опечатка неотличима от недоступного брокера (`17-otp-concurrency.md`).

  Опции процесса проверяет схема над `init/1` (`use Core.Options`, `@opts_schema`), а доменные
  значения — custom-типы схемы `{:custom, Core.Helper.StartOpts, fun, args}`: `prim/2`,
  `module/1`, `atom/1`, `binary/1`, `term/1`, `name/1`, `topics_filter/1`, `shutdown/1`. Они
  возвращают `{:ok, value}` или `{:error, "ожидается …, получено …"}`; ключ в текст отказа
  добавляет NimbleOptions. Простые значения (целое, булево, функция, атом, где допустим `nil`) —
  встроенные типы NimbleOptions.

  `process!/3` и `unique!/4` — для готовых деревьев: они проверяют значение, а не достают его из
  `opts`, потому что процессы дерева приходят вложенными в элементы его списков. `label` — имя
  дерева для текста ошибки (`"Outbox.Supervisor"`).

  `Core.Helper.Opts` — про опции `use`-макросов и compile-time; здесь — рантайм.
  """

  alias Core.Result

  @typedoc "Процесс, который поднимает дерево: модуль, его опции и имя — оно же `id` ребёнка и handle."
  @type process :: %{module: module(), opts: keyword(), name: atom()}

  @process_expected "{модуль, опции с name: атомом}"
  @name_expected "имя процесса (атом, {:global, term} или {:via, module, term})"
  @topics_filter_expected ":all, {:only, [String.t()]} или {:except, [String.t()]}"
  @shutdown_expected "неотрицательное целое, :infinity или :brutal_kill"

  # ===== custom-валидаторы схемы =====

  @doc "Значение — структура `mod` (Prim): `{:custom, Core.Helper.StartOpts, :prim, [mod]}`."
  @spec prim(term(), module()) :: Result.t(struct(), String.t())

  def prim(%{__struct__: mod} = value, mod) when is_atom(mod), do: {:ok, value}
  def prim(value, mod) when is_atom(mod), do: invalid("%#{inspect(mod)}{}", value)

  @doc "Значение — модуль: атом, кроме `nil`; `{:custom, Core.Helper.StartOpts, :module, []}`."
  @spec module(term()) :: Result.t(module(), String.t())

  def module(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  def module(value), do: invalid("модуль", value)

  @doc "Значение — атом, кроме `nil` (имя, ключ, тег): `{:custom, Core.Helper.StartOpts, :atom, []}`."
  @spec atom(term()) :: Result.t(atom(), String.t())

  def atom(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  def atom(value), do: invalid("атом", value)

  @doc "Значение — непустая строка: `{:custom, Core.Helper.StartOpts, :binary, []}`."
  @spec binary(term()) :: Result.t(String.t(), String.t())

  def binary(value) when is_binary(value) and value != "", do: {:ok, value}
  def binary(value), do: invalid("непустая строка", value)

  @doc "Значение — любое, кроме `nil` (handle процесса); `{:custom, Core.Helper.StartOpts, :term, []}`."
  @spec term(term()) :: Result.t(term(), String.t())

  def term(nil), do: invalid("значение", nil)
  def term(value), do: {:ok, value}

  @doc """
  Значение — имя процесса (`GenServer.name()`) или `nil` — процесс без имени;
  `{:custom, Core.Helper.StartOpts, :name, []}`.
  """
  @spec name(term()) :: Result.t(GenServer.name() | nil, String.t())

  def name(value) when is_atom(value), do: {:ok, value}
  def name({:global, _term} = value), do: {:ok, value}
  def name({:via, mod, _term} = value) when is_atom(mod), do: {:ok, value}
  def name(value), do: invalid(@name_expected, value)

  @doc """
  Значение — фильтр топиков `Core.Outbox.topics_filter()`;
  `{:custom, Core.Helper.StartOpts, :topics_filter, []}`.
  """
  @spec topics_filter(term()) :: Result.t(Core.Outbox.topics_filter(), String.t())

  def topics_filter(:all), do: {:ok, :all}

  def topics_filter({mode, topics} = value) when mode in ~w(only except)a and is_list(topics) do
    if Enum.all?(topics, &is_binary/1),
      do: {:ok, value},
      else: invalid(@topics_filter_expected, value)
  end

  def topics_filter(value), do: invalid(@topics_filter_expected, value)

  @doc "Значение — `shutdown` ребёнка супервизора; `{:custom, Core.Helper.StartOpts, :shutdown, []}`."
  @spec shutdown(term()) :: Result.t(timeout() | :brutal_kill, String.t())

  def shutdown(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def shutdown(value) when value in ~w(infinity brutal_kill)a, do: {:ok, value}
  def shutdown(value), do: invalid(@shutdown_expected, value)

  # ---

  defp invalid(expected, value), do: {:error, "ожидается #{expected}, получено #{inspect(value)}"}

  # ===== процессы дерева =====

  @doc "Процесс дерева `{модуль, опции}` с `name:` — атомом в опциях; `key` — опция для текста ошибки."
  @spec process!(String.t(), atom(), term()) :: process()

  def process!(label, key, {module, opts} = spec) when is_atom(module) and not is_nil(module) and is_list(opts) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and not is_nil(name) -> %{module: module, opts: opts, name: name}
      _other -> invalid!(label, key, @process_expected, spec)
    end
  end

  def process!(label, key, spec), do: invalid!(label, key, @process_expected, spec)

  @doc "Значения без повторов; повторы — ошибка с их списком, `expected` — правило для текста."
  @spec unique!(String.t(), atom(), String.t(), list()) :: :ok

  def unique!(label, key, expected, values) when is_list(values) do
    case Enum.uniq(values -- Enum.uniq(values)) do
      [] -> :ok
      repeated -> invalid!(label, key, expected, repeated)
    end
  end

  # ---

  defp invalid!(label, key, expected, value) do
    raise ArgumentError,
          "#{label}: опция #{inspect(key)} — ожидается #{expected}, получено #{inspect(value)}"
  end
end
