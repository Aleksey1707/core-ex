defmodule Core.Helper.StartOpts do
  @moduledoc """
  Проверка опций OTP-процесса в `init/1`.

  Опции приходят из дерева супервизии потребителя и разбираются один раз: ошибка в них —
  ошибка конфигурации. `ArgumentError` в `init/1` называет опцию и ожидаемое значение,
  тогда как непроверенное значение всплывает позже и хуже: `FunctionClauseError` в
  `handle_continue/2` (супервизор уходит в цикл рестартов) или молчаливый backoff, в
  котором опечатка неотличима от недоступного брокера (`17-otp-concurrency.md`).

  Процесс, переведённый на схему опций (`use Core.Options`, `@opts_schema` над `init/1`), проверяет
  доменные значения custom-типами схемы `{:custom, Core.Helper.StartOpts, fun, args}`: `prim/2`,
  `module/1`, `name/1`, `topics_filter/1`, `shutdown/1`. Они возвращают `{:ok, value}` или
  `{:error, "ожидается …, получено …"}`; ключ в текст отказа добавляет NimbleOptions. Простые
  значения (целое, булево, функция, атом) — встроенные типы NimbleOptions.

  Проверки опций с `!` — для процессов, ещё не переведённых на схему; `process!/3` и `unique!/4`
  проверяют значения внутри списков дерева и нужны и при схеме.

  `Core.Helper.Opts` — про опции `use`-макросов и compile-time; здесь — рантайм.
  `label` у функций с `!` — имя процесса для текста ошибки (`"Mq.Stream.Reader"`).

  `keys!/3` ловит опечатку в имени необязательной опции: без него такая опция молча берёт
  значение по умолчанию.

  `process!/3` и `unique!/4` — для готовых деревьев: они проверяют значение, а не достают его из
  `opts`, потому что процессы дерева приходят вложенными в элементы его списков.
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

  # ===== проверки с raise =====

  @doc "Опции — только из `allowed`; неизвестная — ошибка с её именем."
  @spec keys!(String.t(), keyword(), [atom()]) :: :ok

  def keys!(label, opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{label}: неизвестные опции #{inspect(Enum.uniq(unknown))}, допустимые: #{inspect(allowed)}"
    end
  end

  @doc "Обязательная опция-модуль."
  @spec module!(String.t(), keyword(), atom()) :: module()

  def module!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> value
      {:ok, other} -> raise_invalid!(label, key, "модуль", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Опция — модуль или `nil`; `default` при отсутствии."
  @spec module!(String.t(), keyword(), atom(), module() | nil) :: module() | nil

  def module!(label, opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_atom(value) -> value
      other -> raise_invalid!(label, key, "модуль", other)
    end
  end

  @doc "Обязательная опция — структура `mod`."
  @spec prim!(String.t(), keyword(), atom(), module()) :: struct()

  def prim!(label, opts, key, mod) do
    case Keyword.fetch(opts, key) do
      {:ok, %{__struct__: ^mod} = value} -> value
      {:ok, other} -> raise_invalid!(label, key, "%#{inspect(mod)}{}", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция-атом (имя, ключ, тег)."
  @spec atom!(String.t(), keyword(), atom()) :: atom()

  def atom!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> value
      {:ok, other} -> raise_invalid!(label, key, "атом", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция — непустая строка."
  @spec binary!(String.t(), keyword(), atom()) :: String.t()

  def binary!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      {:ok, other} -> raise_invalid!(label, key, "непустую строку", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Опция — непустая строка; `default` при отсутствии."
  @spec binary!(String.t(), keyword(), atom(), String.t()) :: String.t()

  def binary!(label, opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_binary(value) and value != "" -> value
      other -> raise_invalid!(label, key, "непустую строку", other)
    end
  end

  @doc "Обязательная опция — список; элементы проверяет вызывающий."
  @spec list!(String.t(), keyword(), atom()) :: list()

  def list!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_list(value) -> value
      {:ok, other} -> raise_invalid!(label, key, "список", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция — любое значение, кроме `nil`; форму проверяет вызывающий."
  @spec term!(String.t(), keyword(), atom()) :: term()

  def term!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> raise_invalid!(label, key, "значение", nil)
      {:ok, value} -> value
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция — функция арности `arity`."
  @spec fun!(String.t(), keyword(), atom(), arity()) :: function()

  def fun!(label, opts, key, arity) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_function(value, arity) -> value
      {:ok, other} -> raise_invalid!(label, key, "функция арности #{arity}", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Опция — функция арности `arity`; `default` при отсутствии."
  @spec fun!(String.t(), keyword(), atom(), arity(), function()) :: function()

  def fun!(label, opts, key, arity, default) do
    case Keyword.get(opts, key, default) do
      value when is_function(value, arity) -> value
      other -> raise_invalid!(label, key, "функция арности #{arity}", other)
    end
  end

  @doc "Обязательная опция — положительное целое."
  @spec pos_integer!(String.t(), keyword(), atom()) :: pos_integer()

  def pos_integer!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      {:ok, other} -> raise_invalid!(label, key, "положительное целое", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Опция — положительное целое; `default` при отсутствии."
  @spec pos_integer!(String.t(), keyword(), atom(), pos_integer()) :: pos_integer()

  def pos_integer!(label, opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise_invalid!(label, key, "положительное целое", other)
    end
  end

  @doc "Обязательная опция — булево."
  @spec boolean!(String.t(), keyword(), atom()) :: boolean()

  def boolean!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_boolean(value) -> value
      {:ok, other} -> raise_invalid!(label, key, "true или false", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Опция — булево; `default` при отсутствии."
  @spec boolean!(String.t(), keyword(), atom(), boolean()) :: boolean()

  def boolean!(label, opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      other -> raise_invalid!(label, key, "true или false", other)
    end
  end

  @doc "Опция — значение из `allowed`; `default` при отсутствии."
  @spec one_of!(String.t(), keyword(), atom(), [term()], term()) :: term()

  def one_of!(label, opts, key, allowed, default) do
    value = Keyword.get(opts, key, default)

    if value in allowed,
      do: value,
      else: raise_invalid!(label, key, "одно из #{inspect(allowed)}", value)
  end

  @doc "Опция — фильтр топиков `Core.Outbox.topics_filter()`; `default` при отсутствии."
  @spec topics_filter!(String.t(), keyword(), atom(), Core.Outbox.topics_filter()) :: Core.Outbox.topics_filter()

  def topics_filter!(label, opts, key, default),
    do: unwrap!(topics_filter(Keyword.get(opts, key, default)), label, key)

  @doc "Опция — имя процесса (`GenServer.name()`); `nil` — процесс без имени, он же при отсутствии."
  @spec name!(String.t(), keyword(), atom()) :: GenServer.name() | nil

  def name!(label, opts, key), do: unwrap!(name(Keyword.get(opts, key)), label, key)

  @doc "Опция — `shutdown` ребёнка супервизора; `default` при отсутствии."
  @spec shutdown!(String.t(), keyword(), atom(), timeout() | :brutal_kill) :: timeout() | :brutal_kill

  def shutdown!(label, opts, key, default),
    do: unwrap!(shutdown(Keyword.get(opts, key, default)), label, key)

  @doc "Процесс дерева `{модуль, опции}` с `name:` — атомом в опциях; `key` — опция для текста ошибки."
  @spec process!(String.t(), atom(), term()) :: process()

  def process!(label, key, {module, opts} = spec) when is_atom(module) and not is_nil(module) and is_list(opts) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and not is_nil(name) -> %{module: module, opts: opts, name: name}
      _other -> raise_invalid!(label, key, @process_expected, spec)
    end
  end

  def process!(label, key, spec), do: raise_invalid!(label, key, @process_expected, spec)

  @doc "Значения без повторов; повторы — ошибка с их списком, `expected` — правило для текста."
  @spec unique!(String.t(), atom(), String.t(), list()) :: :ok

  def unique!(label, key, expected, values) when is_list(values) do
    case Enum.uniq(values -- Enum.uniq(values)) do
      [] -> :ok
      repeated -> raise_invalid!(label, key, expected, repeated)
    end
  end

  @doc "Поднять ошибку о недопустимом значении опции: для проверок сложнее перечисления."
  @spec raise_invalid!(String.t(), atom(), String.t(), term()) :: no_return()

  def raise_invalid!(label, key, expected, value) do
    raise ArgumentError,
          "#{label}: опция #{inspect(key)} — ожидается #{expected}, получено #{inspect(value)}"
  end

  # ---

  defp unwrap!({:ok, value}, _label, _key), do: value
  defp unwrap!({:error, message}, label, key), do: raise(ArgumentError, "#{label}: опция #{inspect(key)} — #{message}")

  defp raise_missing!(label, key) do
    raise ArgumentError, "#{label}: нет обязательной опции #{inspect(key)}"
  end
end
