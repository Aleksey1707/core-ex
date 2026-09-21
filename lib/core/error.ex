defmodule Core.Error do
  @moduledoc """
  Структурированная ошибка предметной области или приложения.

  Поля:

  - `kind` — `:domain` или `:app`
  - `ns` — пространство имён ошибок
  - `module` — модуль-источник
  - `code` — атом кода
  - `message` — текст для клиента / логов
  - `detail` — произвольный контекст (`term()`), без фиксированной формы
  - `parent` — опциональная внутренняя ошибка (cause), аналог Go `errors.Unwrap`
  - `errors` — состав множества ошибок, по умолчанию `[]`

  `parent` и `errors` — разные отношения и независимы друг от друга: `parent` отвечает
  «почему» (линейная цепочка причин), `errors` — «что ещё не так» (плоский набор независимых
  отказов одной операции). Решение о форме — ADR-0021.

  Фабрики: макросы `domain/1`, `domain/2`, `app/1`, `app/2`, `many/1`, `many/2`.
  На call site: `require Error` (рядом с `alias`).

  - `/1` — `module` из `__CALLER__.module` (прямые call site'ы).
  - `/2` — явный `module` (каталоги `*.Errors`, чужой источник).
  - `domain`: обязательны `code:`, `ns:`, `message:`; опциональны `detail:`, `parent:`
  - `app`: обязательны `code:`, `ns:`; опциональны `message:`, `detail:`, `parent:`
  - `many`: обязательны `code:`, `ns:`, `message:`, `errors:`; опциональны `detail:`, `parent:`

  `many` не принимает `kind:` — он выводится по слабейшему звену состава: хотя бы один
  элемент `:app` → контейнер `:app`. Состав плоский и непустой, порядок входа сохраняется.
  Контейнер не бывает причиной: `wrap/2` вторым аргументом и `parent:` его не принимают.

  Литеральный keyword-список attrs проверяется на этапе компиляции (required / unknown / дубли).
  Динамический attrs (переменная) — без compile-check; runtime через `__domain__/2` /
  `__app__/2` / `__many__/2`: отсутствие обязательного — `KeyError`, лишний ключ —
  `ArgumentError`.

  Оборачивание: `wrap/2` или `parent:` в attrs.
  Обход цепочки: `unwrap/1`, `root/1`, `chain/1`, `has?/2`, `find/2`.

  Граница обхода: `unwrap/1`, `root/1`, `chain/1`, `has?/2`, `find/2` и `Enumerable` читают
  **только** цепочку причин — состав множества им не виден (`has?/2` по коду элемента даёт
  `false`, `Enum.count/1` считает цепочку). Состав читается из поля `errors`: `messages/1` —
  тексты элементов для клиента, `format_chain/1` — печать `"outer (e1 | e2): root"` для лога.
  Решение о форме и цена — ADR-0021.

  `%Error{}` реализует `Enumerable`: итерация = cause-цепочка `[outer, …, root]`
  (`Enum.find/2`, `for`, `in` и т.п.). Обратная сторона: `%Error{}`, попавший в `Enum.*`
  вместо списка, не упадёт, а вернёт цепочку — проверять форму до итерации.
  """

  @enforce_keys ~w(kind ns code module message detail)a
  defstruct [:kind, :ns, :module, :code, :message, :detail, parent: nil, errors: []]

  @type kind :: :domain | :app
  @type t :: %__MODULE__{
          kind: kind(),
          ns: atom(),
          module: module(),
          code: atom(),
          message: String.t() | nil,
          detail: term(),
          parent: t() | nil,
          errors: [t()]
        }

  @type filter :: [{:ns | :code | :kind | :module, term()}, ...]

  @filter_keys ~w(ns code kind module)a

  @domain_required ~w(code ns message)a
  @domain_optional ~w(detail parent)a
  @app_required ~w(code ns)a
  @app_optional ~w(message detail parent)a
  @many_required ~w(code ns message errors)a
  @many_optional ~w(detail parent)a

  @not_a_cause "множество ошибок не может быть причиной"

  # ===== конструкторы =====

  @doc """
  Собрать доменную ошибку; `module` = `__CALLER__.module`.

  См. `domain/2`.
  """
  defmacro domain(attrs) do
    module = __CALLER__.module

    quote do
      unquote(__MODULE__).domain(unquote(module), unquote(attrs))
    end
  end

  @doc """
  Собрать доменную ошибку.

  Обязательные attrs: `code:`, `ns:`, `message:`.
  Опциональные: `detail:`, `parent:`.

  Литеральный keyword-список — проверка ключей на compile-time.
  """
  defmacro domain(module, attrs) do
    if literal_keyword_ast?(attrs) do
      validate_factory_opts!(attrs, @domain_required, @domain_optional, __CALLER__)
    end

    quote do
      unquote(__MODULE__).__domain__(unquote(module), unquote(attrs))
    end
  end

  @doc """
  Собрать прикладную ошибку; `module` = `__CALLER__.module`.

  См. `app/2`.
  """
  defmacro app(attrs) do
    module = __CALLER__.module

    quote do
      unquote(__MODULE__).app(unquote(module), unquote(attrs))
    end
  end

  @doc """
  Собрать прикладную ошибку.

  Обязательные attrs: `code:`, `ns:`.
  Опциональные: `message:`, `detail:`, `parent:`.

  Литеральный keyword-список — проверка ключей на compile-time.
  """
  defmacro app(module, attrs) do
    if literal_keyword_ast?(attrs) do
      validate_factory_opts!(attrs, @app_required, @app_optional, __CALLER__)
    end

    quote do
      unquote(__MODULE__).__app__(unquote(module), unquote(attrs))
    end
  end

  @doc """
  Собрать множество ошибок; `module` = `__CALLER__.module`.

  См. `many/2`.
  """
  defmacro many(attrs) do
    module = __CALLER__.module

    quote do
      unquote(__MODULE__).many(unquote(module), unquote(attrs))
    end
  end

  @doc """
  Собрать множество независимых отказов одной операции.

  Обязательные attrs: `code:`, `ns:`, `message:`, `errors:`.
  Опциональные: `detail:`, `parent:`.

  `kind` выводится из состава: хотя бы один элемент `:app` → контейнер `:app`.

  Литеральный keyword-список — проверка ключей на compile-time.
  """
  defmacro many(module, attrs) do
    if literal_keyword_ast?(attrs) do
      validate_factory_opts!(attrs, @many_required, @many_optional, __CALLER__)
    end

    quote do
      unquote(__MODULE__).__many__(unquote(module), unquote(attrs))
    end
  end

  @doc false
  @spec __domain__(module(), keyword()) :: t()

  def __domain__(module, attrs) when is_atom(module) and is_list(attrs) do
    build(:domain, module, take_attrs(attrs, @domain_required, @domain_optional))
  end

  @doc false
  @spec __app__(module(), keyword()) :: t()

  def __app__(module, attrs) when is_atom(module) and is_list(attrs) do
    build(:app, module, take_attrs(attrs, @app_required, @app_optional))
  end

  @doc false
  @spec __many__(module(), keyword()) :: t()

  def __many__(module, attrs) when is_atom(module) and is_list(attrs) do
    %{errors: errors} = fields = take_attrs(attrs, @many_required, @many_optional)

    validate_errors!(errors)

    %{build(weakest_kind(errors), module, fields) | errors: errors}
  end

  # ---

  defp take_attrs(attrs, required, optional) do
    validate_attr_keys!(attrs, required ++ optional)

    fields = Map.new(required, &{&1, Keyword.fetch!(attrs, &1)})

    Enum.into(optional, fields, &{&1, Keyword.get(attrs, &1)})
  end

  defp validate_attr_keys!(attrs, allowed) do
    unknown =
      attrs
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in allowed))

    if unknown != [], do: raise(ArgumentError, "неизвестные опции: #{inspect(unknown)}")
  end

  defp build(kind, module, %{code: code, ns: ns, message: message} = fields) do
    %{detail: detail, parent: parent} = fields

    error = %__MODULE__{
      kind: kind,
      module: module,
      code: code,
      ns: ns,
      message: message,
      detail: detail,
      parent: nil,
      errors: []
    }

    put_parent(error, parent)
  end

  defp put_parent(error, nil), do: error
  defp put_parent(_error, %__MODULE__{errors: [_ | _]}), do: raise(ArgumentError, @not_a_cause)
  defp put_parent(error, %__MODULE__{} = parent), do: %{error | parent: parent}

  defp validate_errors!([]), do: raise(ArgumentError, "множество ошибок не может быть пустым")

  defp validate_errors!([_ | _] = errors), do: Enum.each(errors, &validate_element!/1)

  defp validate_element!(%__MODULE__{errors: []}), do: :ok

  defp validate_element!(%__MODULE__{}) do
    raise ArgumentError, "множество ошибок плоское: элемент не может нести собственное множество"
  end

  defp validate_element!(other) do
    raise ArgumentError,
          "элемент множества ошибок должен быть %Core.Error{}, получено: #{inspect(other)}"
  end

  defp weakest_kind(errors) do
    if Enum.any?(errors, &match?(%__MODULE__{kind: :app}, &1)),
      do: :app,
      else: :domain
  end

  defp literal_keyword_ast?(attrs) when is_list(attrs) do
    Enum.all?(attrs, fn
      {key, _value} when is_atom(key) -> true
      _ -> false
    end)
  end

  defp literal_keyword_ast?(_attrs), do: false

  defp validate_factory_opts!(attrs, required, optional, caller) do
    keys =
      Enum.map(attrs, fn
        {key, _value} when is_atom(key) -> key
      end)

    missing = Enum.reject(required, &(&1 in keys))

    if missing != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "нет обязательных опций: #{inspect(missing)}"
    end

    duplicated =
      keys
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(fn {key, _count} -> key end)

    if duplicated != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "дублирующиеся опции: #{inspect(duplicated)}"
    end

    allowed = required ++ optional

    unknown =
      keys
      |> Enum.uniq()
      |> Enum.reject(&(&1 in allowed))

    if unknown != [] do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "неизвестные опции: #{inspect(unknown)}"
    end

    :ok
  end

  # ===== цепочка причин =====

  @doc """
  Обернуть ошибку: установить `parent` (cause).

  Если у `error` уже есть цепочка, новый cause подцепляется в её **конец** и становится
  `root/1`: иначе `wrap` молча терял бы всё, что ниже.

  Множество ошибок причиной не бывает: контейнер вторым аргументом — `ArgumentError`.
  """
  @spec wrap(t(), t()) :: t()

  def wrap(%__MODULE__{}, %__MODULE__{errors: [_ | _]}), do: raise(ArgumentError, @not_a_cause)

  def wrap(%__MODULE__{parent: nil} = error, %__MODULE__{} = parent),
    do: %{error | parent: parent}

  def wrap(%__MODULE__{parent: existing} = error, %__MODULE__{} = parent) do
    %{error | parent: wrap(existing, parent)}
  end

  @doc "Вернуть parent (cause) или `nil`."
  @spec unwrap(t()) :: t() | nil

  def unwrap(%__MODULE__{parent: parent}), do: parent

  @doc "Корневая (самая внутренняя) ошибка цепочки."
  @spec root(t()) :: t()

  def root(%__MODULE__{parent: nil} = error), do: error
  def root(%__MODULE__{parent: parent}), do: root(parent)

  @doc "Цепочка ошибок от outer к root."
  @spec chain(t()) :: [t()]

  def chain(%__MODULE__{} = error), do: do_chain(error, [])

  @doc """
  Есть ли в цепочке узел, совпадающий с keyword-критерием.

  Ключи: `ns:`, `code:`, `kind:`, `module:` (все указанные должны совпасть).
  Неизвестный ключ или не keyword-пара — `ArgumentError` сразу: проверка на каждом узле
  срабатывала бы лениво и опечатка выглядела бы как «не нашли».

  Список критериев непустой: пустой совпал бы с любой ошибкой.
  """
  @spec has?(t(), filter()) :: boolean()

  def has?(%__MODULE__{} = error, [_ | _] = opts) do
    Enum.each(opts, &validate_filter_key!/1)

    find(error, &match_opts?(&1, opts)) != nil
  end

  @doc "Первый узел цепочки, для которого `fun` истинно; иначе `nil`."
  @spec find(t(), (t() -> as_boolean(term()))) :: t() | nil

  def find(%__MODULE__{} = error, fun) when is_function(fun, 1),
    do: Enum.find(error, fun)

  @doc """
  Сообщения цепочки через `\": \"` (для логов, не для HTTP-клиента).

  Узел с непустым `errors` печатается вместе с составом: `"outer (e1 | e2): root"`;
  элемент состава — своей цепочкой причин. У ошибки с пустым `errors` вывод прежний.
  """
  @spec format_chain(t()) :: String.t()

  def format_chain(%__MODULE__{} = error),
    do: Enum.map_join(error, ": ", &format_node/1)

  # ---

  defp do_chain(%__MODULE__{parent: nil} = error, acc), do: Enum.reverse([error | acc])
  defp do_chain(%__MODULE__{parent: parent} = error, acc), do: do_chain(parent, [error | acc])

  defp match_opts?(error, opts) do
    Enum.all?(opts, fn {key, value} -> Map.fetch!(error, key) == value end)
  end

  defp validate_filter_key!({key, _value}) when key in @filter_keys, do: :ok

  defp validate_filter_key!({key, _value}) do
    raise ArgumentError, "неизвестный ключ фильтра has?: #{inspect(key)}"
  end

  defp validate_filter_key!(other) do
    raise ArgumentError, "критерий has? должен быть keyword-парой, получено: #{inspect(other)}"
  end

  defp format_node(%__MODULE__{errors: []} = error), do: to_string(error)

  defp format_node(%__MODULE__{errors: errors} = error),
    do: "#{error} (#{Enum.map_join(errors, " | ", &format_chain/1)})"

  # ===== состав =====

  @doc """
  Тексты для клиента: у контейнера — `to_string/1` каждого элемента в порядке состава,
  у обычной ошибки — `[to_string(error)]`.

  Цепочку причин не читает: наружу уходит то, что относится к самой ошибке.
  """
  @spec messages(t()) :: [String.t()]

  def messages(%__MODULE__{errors: []} = error), do: [to_string(error)]
  def messages(%__MODULE__{errors: [_ | _] = errors}), do: Enum.map(errors, &to_string/1)

  defimpl String.Chars do
    @impl true
    def to_string(%Core.Error{message: message}) when is_binary(message) and message != "",
      do: message

    def to_string(%Core.Error{ns: ns, code: code}), do: "#{ns}/#{code}"
  end

  defimpl Enumerable do
    @impl true
    def reduce(error, acc, fun),
      do: Enumerable.List.reduce(Core.Error.chain(error), acc, fun)

    @impl true
    def count(error),
      do: {:ok, length(Core.Error.chain(error))}

    @impl true
    def member?(error, element),
      do: {:ok, element in Core.Error.chain(error)}

    @impl true
    def slice(error) do
      list = Core.Error.chain(error)
      size = length(list)

      {:ok, size,
       fn start, amount, step ->
         list
         |> Enum.drop(start)
         |> Enum.take_every(step)
         |> Enum.take(amount)
       end}
    end
  end
end
