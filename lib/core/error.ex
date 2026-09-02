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

  Фабрики: макросы `domain/1`, `domain/2`, `app/1`, `app/2`.
  На call site: `require Error` (рядом с `alias`).

  - `/1` — `module` из `__CALLER__.module` (прямые call site'ы).
  - `/2` — явный `module` (каталоги `*.Errors`, чужой источник).
  - `domain`: обязательны `code:`, `ns:`, `message:`; опциональны `detail:`, `parent:`
  - `app`: обязательны `code:`, `ns:`; опциональны `message:`, `detail:`, `parent:`

  Литеральный keyword-список attrs проверяется на этапе компиляции (required / unknown keys).
  Динамический attrs (переменная) — без compile-check; runtime через `__domain__/2` / `__app__/2`
  и `Keyword.fetch!`.

  Оборачивание: `wrap/2` или `parent:` в attrs.
  Обход цепочки: `unwrap/1`, `root/1`, `chain/1`, `has?/2`, `find/2`, `format_chain/1`.

  `%Error{}` реализует `Enumerable`: итерация = cause-цепочка `[outer, …, root]`
  (`Enum.find/2`, `for`, `in` и т.п.).
  """

  @enforce_keys ~w(kind ns code module detail)a
  defstruct kind: nil,
            ns: nil,
            module: nil,
            code: nil,
            message: nil,
            detail: nil,
            parent: nil

  @type kind :: :domain | :app
  @type t :: %__MODULE__{
          kind: kind(),
          ns: atom(),
          module: module(),
          code: atom(),
          message: String.t() | nil,
          detail: term(),
          parent: t() | nil
        }

  @domain_required ~w(code ns message)a
  @domain_optional ~w(detail parent)a
  @app_required ~w(code ns)a
  @app_optional ~w(message detail parent)a

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

  @doc false
  @spec __domain__(module(), keyword()) :: t()

  def __domain__(module, attrs) when is_atom(module) and is_list(attrs) do
    build(:domain, module,
      code: Keyword.fetch!(attrs, :code),
      ns: Keyword.fetch!(attrs, :ns),
      message: Keyword.fetch!(attrs, :message),
      detail: Keyword.get(attrs, :detail),
      parent: Keyword.get(attrs, :parent)
    )
  end

  @doc false
  @spec __app__(module(), keyword()) :: t()

  def __app__(module, attrs) when is_atom(module) and is_list(attrs) do
    build(:app, module,
      code: Keyword.fetch!(attrs, :code),
      ns: Keyword.fetch!(attrs, :ns),
      message: Keyword.get(attrs, :message),
      detail: Keyword.get(attrs, :detail),
      parent: Keyword.get(attrs, :parent)
    )
  end

  @doc "Обернуть ошибку: установить `parent` (cause)."
  @spec wrap(t(), t()) :: t()

  def wrap(%__MODULE__{parent: nil} = error, %__MODULE__{} = parent),
    do: %{error | parent: parent}

  # У outer уже есть cause: подцепляем новый в конец цепочки, иначе `wrap` молча терял бы
  # всё, что ниже (и вместе с ним — `root/1`, `chain/1`, `has?/2`).
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
  Неизвестный ключ — `ArgumentError` сразу: проверка на каждом узле срабатывала бы
  лениво и опечатка выглядела бы как «не нашли».
  """
  @spec has?(t(), keyword()) :: boolean()

  def has?(%__MODULE__{} = error, opts) when is_list(opts) do
    Enum.each(opts, &validate_filter_key!/1)

    find(error, &match_opts?(&1, opts)) != nil
  end

  @doc "Первый узел цепочки, для которого `fun` истинно; иначе `nil`."
  @spec find(t(), (t() -> as_boolean(term()))) :: t() | nil

  def find(%__MODULE__{} = error, fun) when is_function(fun, 1),
    do: Enum.find(error, fun)

  @doc "Сообщения цепочки через `\": \"` (для логов, не для HTTP-клиента)."
  @spec format_chain(t()) :: String.t()

  def format_chain(%__MODULE__{} = error),
    do: Enum.map_join(error, ": ", &to_string/1)

  # ---

  defp build(kind, module, fields) do
    parent = fields[:parent]

    if not is_nil(parent) and not match?(%__MODULE__{}, parent) do
      raise ArgumentError, "parent must be %Error{} or nil, got: #{inspect(parent)}"
    end

    %__MODULE__{
      kind: kind,
      module: module,
      code: fields[:code],
      ns: fields[:ns],
      message: fields[:message],
      detail: fields[:detail],
      parent: parent
    }
  end

  defp do_chain(%__MODULE__{parent: nil} = error, acc), do: Enum.reverse([error | acc])
  defp do_chain(%__MODULE__{parent: parent} = error, acc), do: do_chain(parent, [error | acc])

  defp match_opts?(error, opts) do
    Enum.all?(opts, fn
      {:ns, ns} -> error.ns == ns
      {:code, code} -> error.code == code
      {:kind, kind} -> error.kind == kind
      {:module, module} -> error.module == module
    end)
  end

  defp validate_filter_key!({key, _value}) when key in ~w(ns code kind module)a, do: :ok

  defp validate_filter_key!({key, _value}) do
    raise ArgumentError, "unknown has? filter key: #{inspect(key)}"
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
        description: "missing required option(s): #{inspect(missing)}"
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
        description: "unknown option(s): #{inspect(unknown)}"
    end

    :ok
  end

  defimpl String.Chars do
    @doc false
    @impl true
    def to_string(%{message: message}) when is_binary(message), do: message

    def to_string(%{ns: ns, code: code}), do: "#{ns}/#{code}"
  end

  defimpl Enumerable do
    @doc false
    @impl true
    def reduce(error, acc, fun),
      do: Enumerable.List.reduce(Core.Error.chain(error), acc, fun)

    @doc false
    @impl true
    def count(error),
      do: {:ok, length(Core.Error.chain(error))}

    @doc false
    @impl true
    def member?(error, element),
      do: {:ok, element in Core.Error.chain(error)}

    @doc false
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
