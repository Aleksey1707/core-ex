defmodule Core.Web.Response do
  @moduledoc """
  Конверт ответа API: `%{code, messages}` / `%{code, messages, data}`.

  Готовый конверт на базовом словаре (`Core.Web.Response.Code`) — сам этот модуль.
  Потребителю, которому базовых кодов мало, — билдер:

      defmodule MyAppWeb.Response do
        use Core.Web.Response, codes: MyAppWeb.Response.Code
      end

  Словарь потребителя — `Core.Enum` с целочисленными `codes:`. Он обязан **покрывать**
  `Core.Web.Response.Code.values/0`: эти значения возвращает `Core.Web.ErrorMapper.map/2`,
  и конверт обязан уметь их отдать. Проще всего собрать его поверх базового — тогда
  и покрытие есть, и общие коды не разъедутся:

      use Core.Enum,
        name: first_line(@moduledoc),
        codes: Map.merge(Core.Web.Response.Code.codes(), %{not_found: 10, conflict: 11})

  Свои значения нумеруются любыми целыми кодами вне `Core.Web.Response.Code.reserved_codes/0`
  (`0..9` — за библиотекой); базовым значениям коды менять нельзя. Нарушение — `CompileError`.

  Конверт не зависит ни от Plug, ни от Phoenix: это map, который контроллер отдаёт
  своим `json/2`.
  """

  alias Core.Helper
  alias Core.Pagination
  alias Core.Web.Response

  @required_keys ~w(codes)a
  @optional_keys ~w()a
  @label "Web.Response"
  @codes_exports [{:to_code, 1}, {:codes, 0}, {:values, 0}]

  @doc "Объявить конверт ответа на своём словаре кодов (`codes:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Web.Response.required_keys(),
        Core.Web.Response.optional_keys(),
        Core.Web.Response.label()
      )

      @response_codes Core.Web.Response.codes_module!(opts)

      alias Core.Pagination

      @doc "Успешный ответ без данных."
      @spec success() :: map()

      def success, do: Core.Web.Response.__success__(@response_codes)

      @doc "Успешный ответ с данными."
      @spec success(term()) :: map()

      def success(data), do: Core.Web.Response.__success__(@response_codes, data)

      @doc "Ответ с ошибкой."
      @spec error(atom(), String.t()) :: map()

      def error(code, message), do: Core.Web.Response.__error__(@response_codes, code, message)

      @doc "Страница `{count, items}` через presenter."
      @spec page(Pagination.Result.t(item), (item -> map())) :: map() when item: var

      def page(result, to_map), do: Core.Web.Response.__page__(result, to_map)
    end
  end

  @doc "Успешный ответ без данных."
  @spec success() :: map()

  def success, do: __success__(Response.Code)

  @doc "Успешный ответ с данными."
  @spec success(term()) :: map()

  def success(data), do: __success__(Response.Code, data)

  @doc "Ответ с ошибкой."
  @spec error(Response.Code.t(), String.t()) :: map()

  def error(code, message), do: __error__(Response.Code, code, message)

  @doc "Страница `{count, items}` через presenter."
  @spec page(Pagination.Result.t(item), (item -> map())) :: map() when item: var

  def page(result, to_map), do: __page__(result, to_map)

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec label() :: String.t()

  def label, do: @label

  @doc false
  @spec codes_module!(keyword()) :: module()

  def codes_module!(opts) do
    codes = Helper.Opts.module!(opts, :codes, @label, exports: @codes_exports)

    ensure_integer_codes!(codes)
    ensure_covers_base!(codes)
    ensure_codes_contract!(codes)

    codes
  end

  @doc false
  @spec __success__(module()) :: map()

  def __success__(codes), do: %{code: codes.to_code(:success), messages: []}

  @doc false
  @spec __success__(module(), term()) :: map()

  def __success__(codes, data), do: %{code: codes.to_code(:success), messages: [], data: data}

  @doc false
  @spec __error__(module(), atom(), String.t()) :: map()

  def __error__(codes, code, message) when is_atom(code) and is_binary(message),
    do: %{code: codes.to_code(code), messages: [message]}

  @doc false
  @spec __page__(Pagination.Result.t(item), (item -> map())) :: map() when item: var

  def __page__(%Pagination.Result{items: items, count: count}, to_map)
      when is_function(to_map, 1) do
    %{count: count, items: Enum.map(items, to_map)}
  end

  # ---

  defp ensure_integer_codes!(codes) do
    if Enum.all?(codes.codes(), fn {_value, code} -> is_integer(code) end) do
      :ok
    else
      raise CompileError,
        description: "#{@label}: codes: словарь #{inspect(codes)} обязан иметь целочисленные коды"
    end
  end

  # Базовые значения возвращает `Core.Web.ErrorMapper.map/2`; словарь, который их не знает,
  # упал бы на первой же ошибке в рантайме — ловим на компиляции.
  defp ensure_covers_base!(codes) do
    case Response.Code.values() -- codes.values() do
      [] ->
        :ok

      missing ->
        raise CompileError,
          description:
            "#{@label}: codes: словарь #{inspect(codes)} не покрывает базовые значения " <>
              "#{inspect(missing)} — их возвращает Core.Web.ErrorMapper.map/2"
    end
  end

  # `0..9` — за библиотекой: в них добавляются новые базовые значения, и код, занятый
  # потребителем, разошёлся бы со следующей версией `Core`.
  defp ensure_codes_contract!(codes) do
    base = Response.Code.codes()

    case Enum.reject(codes.codes(), &allowed_code?(&1, base)) do
      [] ->
        :ok

      invalid ->
        raise CompileError,
          description:
            "#{@label}: codes: словарь #{inspect(codes)} нарушает контракт кодов " <>
              "#{inspect(Map.new(invalid))} — базовым значениям коды менять нельзя, " <>
              "свои нумеруются вне #{inspect(Response.Code.reserved_codes())}"
    end
  end

  defp allowed_code?({value, code}, base) do
    case Map.fetch(base, value) do
      {:ok, base_code} -> code == base_code
      :error -> code not in Response.Code.reserved_codes()
    end
  end
end
