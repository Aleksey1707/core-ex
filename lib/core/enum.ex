defmodule Core.Enum do
  @moduledoc """
  Builder закрытого множества атомов (enum).

  Обязательные опции (порядок): `name:`, `values:`.
  Значение — голый атом (не `%Mod{value:}` как у Prim).

  Опционально `codes:` — `%{atom => integer}` для enum, у которых внешний источник
  нумерует значения (справочники с целочисленным ключом). Тогда генерируются
  `from_code/1`, `to_code/1` и `codes/0`. Карта обязана покрывать `values:` целиком
  и не содержать дублей кодов — иначе `CompileError`.
  """

  alias Core.Error
  alias Core.Helper

  require Error

  @required_keys ~w(name)a
  @optional_keys ~w(values codes)a

  @doc "Объявить закрытый enum (`name:` + `values:` либо `codes:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Enum.required_keys(),
        Core.Enum.optional_keys(),
        "Enum"
      )

      name = Keyword.fetch!(opts, :name)
      codes = Keyword.get(opts, :codes)
      values = Core.Enum.values!(Keyword.get(opts, :values), codes)

      unless is_binary(name) do
        raise CompileError, description: "option :name must be a binary"
      end

      alias Core.Error
      alias Core.Result

      @enum_name name
      @enum_values values
      @enum_by_string Map.new(values, fn atom -> {Atom.to_string(atom), atom} end)

      type_ast = Core.Enum.type_union(values)
      @type t :: unquote(type_ast)

      @doc "Допустимые значения enum."
      @spec values() :: [t()]

      def values, do: @enum_values

      @doc "Имя enum (для сообщений об ошибках)."
      @spec name() :: String.t()

      def name, do: @enum_name

      @doc "Проверить, что значение входит в enum."
      @spec member?(term()) :: boolean()

      def member?(value), do: value in @enum_values

      @doc "Привести atom/binary к значению enum."
      @spec cast(term()) :: {:ok, t()} | {:error, Error.t()}

      def cast(value) when value in @enum_values, do: {:ok, value}

      def cast(value) when is_binary(value) do
        case Map.fetch(@enum_by_string, value) do
          {:ok, atom} -> {:ok, atom}
          :error -> Core.Enum.invalid(__MODULE__, @enum_name, value)
        end
      end

      def cast(value), do: Core.Enum.invalid(__MODULE__, @enum_name, value)

      @doc "Как `cast/1`, при ошибке — `raise Exc`."
      @spec cast!(term()) :: t()

      def cast!(value), do: Result.unwrap!(cast(value))

      @doc "Как `cast/1`; `nil` → `{:ok, nil}`."
      @spec cast_optional(term() | nil) :: {:ok, t() | nil} | {:error, Error.t()}

      def cast_optional(nil), do: {:ok, nil}
      def cast_optional(value), do: cast(value)

      @doc "Как `cast_optional/1`, при ошибке — `raise Exc`."
      @spec cast_optional!(term() | nil) :: t() | nil

      def cast_optional!(value), do: Result.unwrap!(cast_optional(value))

      @doc "Значение enum в wire-форму (строка); `nil` → `nil`."
      @spec dump(t() | nil) :: String.t() | nil

      def dump(nil), do: nil

      def dump(value) when value in @enum_values, do: Atom.to_string(value)

      if codes do
        @enum_code_kind Core.Enum.validate_codes!(codes)
        @enum_code_by_value codes
        @enum_value_by_code Map.new(codes, fn {value, code} -> {code, value} end)

        @typedoc "Внешний код значения enum."
        if @enum_code_kind == :integer do
          @type code :: integer()
        else
          @type code :: String.t()
        end

        @doc "Карта `значение => внешний код`."
        @spec codes() :: %{t() => code()}

        def codes, do: @enum_code_by_value

        @doc "Внешний код значения enum."
        @spec to_code(t()) :: code()

        def to_code(value) when value in @enum_values do
          Map.fetch!(@enum_code_by_value, value)
        end

        @doc """
        Внешний код → значение enum.

        Целочисленный код принимается и строкой (`"20"`): внешние источники отдают
        числа текстом. У строкового кода такого приведения нет — иначе `"5"` и `5`
        стали бы одним значением, а строковый код `"5"` перестал бы отличаться от
        целочисленного.
        """
        @spec from_code(term()) :: {:ok, t()} | {:error, Error.t()}

        def from_code(code) when is_map_key(@enum_value_by_code, code) do
          {:ok, Map.fetch!(@enum_value_by_code, code)}
        end

        def from_code(code) when is_binary(code) do
          Core.Enum.from_binary_code(
            __MODULE__,
            @enum_name,
            @enum_value_by_code,
            @enum_code_kind,
            code
          )
        end

        if @enum_code_kind == :integer do
          def from_code(code) when is_integer(code) do
            Core.Enum.invalid(__MODULE__, @enum_name, code)
          end
        end

        @doc "Как `from_code/1`, при ошибке — `raise Exc`."
        @spec from_code!(term()) :: t()

        def from_code!(code), do: Result.unwrap!(from_code(code))
      end
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @typedoc "Тип внешних кодов enum: целые или строки."
  @type code_kind :: :integer | :string

  @doc """
  Список значений enum: из `values:` либо из ключей `codes:`.

  У enum с внешними кодами карта `codes:` уже перечисляет все значения — отдельный
  `values:` был бы вторым списком тех же атомов, который приходится держать в
  синхронности. Поэтому задаётся ровно одно из двух.

  Выведенные значения упорядочены по коду: так `values/0` читается рядом с выгрузкой
  источника, а порядок не зависит от внутреннего устройства map.
  """
  @spec values!(term(), term()) :: [atom()]

  def values!(nil, nil) do
    raise CompileError, description: "Enum: требуется :values либо :codes"
  end

  def values!(values, nil), do: validate_values!(values)

  def values!(nil, codes) do
    validate_codes!(codes)

    codes
    |> Map.keys()
    |> Elixir.Enum.sort_by(&Map.fetch!(codes, &1))
  end

  def values!(_values, _codes) do
    raise CompileError,
      description: "Enum: :values не задаётся вместе с :codes — выводится из ключей карты"
  end

  @doc """
  Проверить карту `codes:` и определить тип кодов.

  Коды обязаны быть одного типа и не повторяться; иначе — `CompileError`.
  """
  @spec validate_codes!(term()) :: code_kind()

  def validate_codes!(codes) do
    kind = code_kind!(codes)

    validate_unique!(codes)

    kind
  end

  # ---

  defp code_kind!(codes) when is_map(codes) and map_size(codes) > 0 do
    cond do
      Elixir.Enum.all?(codes, &valid_pair?(&1, :integer)) -> :integer
      Elixir.Enum.all?(codes, &valid_pair?(&1, :string)) -> :string
      true -> raise CompileError, description: code_kind_error(codes)
    end
  end

  defp code_kind!(codes) do
    raise CompileError,
      description: "option :codes must be a non-empty map, got: #{inspect(codes)}"
  end

  @doc false
  @spec type_union([atom()]) :: Macro.t()

  def type_union([first | rest]) do
    Elixir.Enum.reduce(rest, first, fn atom, acc ->
      {:|, [], [atom, acc]}
    end)
  end

  @doc false
  @spec from_binary_code(module(), String.t(), %{term() => atom()}, code_kind(), String.t()) ::
          {:ok, atom()} | {:error, Error.t()}

  # Сюда приходят только строки, не совпавшие с кодом напрямую: у строкового enum это
  # сразу промах, у целочисленного — ещё не разобранное число («20» из XML-атрибута).
  def from_binary_code(module, name, value_by_code, :integer, code) do
    case Integer.parse(code) do
      {int, ""} -> fetch_code(module, name, value_by_code, int)
      _ -> invalid(module, name, code)
    end
  end

  def from_binary_code(module, name, _value_by_code, :string, code) do
    invalid(module, name, code)
  end

  @doc false
  @spec invalid(module(), String.t(), term()) :: {:error, Error.t()}

  def invalid(module, name, input) when is_binary(name) do
    {:error,
     Error.domain(module,
       code: :invalid_value,
       ns: :enum,
       message: "#{name}: недопустимое значение",
       detail: input
     )}
  end

  # ---

  defp fetch_code(module, name, value_by_code, code) do
    case Map.fetch(value_by_code, code) do
      {:ok, value} -> {:ok, value}
      :error -> invalid(module, name, code)
    end
  end

  defp validate_values!(values) do
    unless is_list(values) and values != [] and Elixir.Enum.all?(values, &is_atom/1) do
      raise CompileError, description: "option :values must be a non-empty list of atoms"
    end

    unless length(values) == length(Elixir.Enum.uniq(values)) do
      raise CompileError, description: "option :values must not contain duplicates"
    end

    values
  end

  # Коды одного типа: карта, где часть значений целые, а часть строки, делает
  # `from_code/1` неоднозначным — `"5"` пришлось бы искать и как строку, и как число.
  defp valid_pair?({value, code}, :integer), do: is_atom(value) and is_integer(code)
  defp valid_pair?({value, code}, :string), do: is_atom(value) and is_binary(code) and code != ""

  defp code_kind_error(codes) do
    "option :codes must map atoms to codes of one type — either all integers or all " <>
      "non-empty strings, got: #{inspect(codes)}"
  end

  defp validate_unique!(codes) do
    unique =
      codes
      |> Map.values()
      |> Elixir.Enum.uniq()

    unless length(unique) == map_size(codes) do
      raise CompileError, description: "option :codes must not contain duplicate codes"
    end

    :ok
  end
end
