defmodule Core.Prim do
  @moduledoc """
  Билдер value object: `%Mod{value:}` + конвейер `cast → mutate → custom_mutate →
  validate → custom_validate`.

  Опции `use`: `cast:`, `mutate:`, `validate:`, `custom_mutate:`, `custom_validate:`,
  `name:`, `kind:` (обязателен), `type_opts:`, `sensitive:`. Типизированные обёртки —
  `Prim.String` / `Integer` / `Decimal` / `UUID` / `DateTime` / `Date` / `Compose`.

  Генерирует `new/1`, `new!/1`, `value/1`, `__domain_kind__/0`, `__domain_type_opts__/0`.
  `sensitive: true` скрывает значение от `inspect/1` и редактирует его в `Error.detail`.
  """

  alias Core.Error
  alias Core.Helper
  alias Core.Result
  alias Core.Validator

  require Error

  @doc "Объявить доменный Prim (`cast` / `name` / `kind` + опциональные mutate/validate)."
  defmacro __using__(opts) do
    {value_type, opts} = Keyword.pop(opts, :value_type, quote(do: term()))

    quote bind_quoted: [opts: opts], unquote: true do
      Helper.Opts.require!(opts, ~w(cast name kind)a, "Prim")

      @cast Keyword.fetch!(opts, :cast)
      @name Keyword.fetch!(opts, :name)
      @domain_kind Keyword.fetch!(opts, :kind)
      @mutate Keyword.get(opts, :mutate)
      @validate Keyword.get(opts, :validate)
      @custom_mutate Keyword.get(opts, :custom_mutate)
      @custom_validate Keyword.get(opts, :custom_validate)
      @type_opts Keyword.get(opts, :type_opts, [])
      @sensitive Keyword.get(opts, :sensitive, false)

      @enforce_keys ~w(value)a

      if @sensitive do
        @derive {Inspect, except: ~w(value)a}
      end

      defstruct ~w(value)a

      @type t :: %__MODULE__{value: unquote(value_type)}

      @doc "Создать Prim из raw."
      @spec new(term()) :: {:ok, t()} | {:error, Error.t()}

      def new(raw) do
        with {:ok, value} <- Core.Prim.normalize_ok(@cast.(raw)),
             {:ok, value} <-
               Core.Prim.run_mutates(@mutate, value, @type_opts),
             {:ok, value} <-
               Core.Prim.run_mutates(@custom_mutate, value, @type_opts),
             :ok <-
               Core.Prim.normalize_validate(Validator.run(@validate, value, @type_opts)),
             :ok <-
               Core.Prim.run_validates(@custom_validate, value, @type_opts) do
          {:ok, %__MODULE__{value: value}}
        else
          {:error, {code, detail}} ->
            {:error,
             Core.Prim.wrap_error(
               __MODULE__,
               @name,
               code,
               detail,
               Core.Prim.redact(raw, @sensitive)
             )}

          {:error, %Error{} = parent} ->
            {:error, Core.Prim.wrap_parent(__MODULE__, @name, parent, raw, @sensitive)}
        end
      end

      @doc "Создать Prim; при ошибке — raise."
      @spec new!(term()) :: t()

      def new!(raw), do: Result.unwrap!(new(raw))

      @doc "Достать внутреннее значение."
      @spec value(t()) :: term()

      def value(%__MODULE__{value: value}), do: value

      @doc "Имя Prim (для сообщений об ошибках)."
      @spec name() :: String.t()

      def name, do: @name

      @doc "Domain kind Prim-обёртки."
      @spec __domain_kind__() :: atom()

      def __domain_kind__, do: @domain_kind

      @doc "Prim объявлен чувствительным (`sensitive: true`)."
      @spec __domain_sensitive__() :: boolean()

      def __domain_sensitive__, do: @sensitive

      @doc """
      Опции типа, с которыми объявлен Prim (`precision`, `tz`, границы).

      Нужны потребителям, которые приводят к wire значение **без** Prim-обёртки
      (`Codec.dump_raw_as/2` на read-пути): без них формат зависел бы только от kind,
      и значение из колонки разошлось бы с тем же значением, прошедшим через Prim.
      """
      @spec __domain_type_opts__() :: keyword()

      def __domain_type_opts__, do: @type_opts
    end
  end

  @type error :: {:error, {atom(), String.t()}} | {:error, Error.t()}

  @native_kinds ~w(uuid datetime date decimal integer string)a
  @composite_kind :composite

  @doc "Native kinds доменных Prim-обёрток."
  @spec native_kinds() :: [atom()]

  def native_kinds, do: @native_kinds

  @doc "Зарезервированные kinds: native + `:composite`."
  @spec reserved_kinds() :: [atom()]

  def reserved_kinds, do: @native_kinds ++ [@composite_kind]

  @doc "Проверка kind обёртки: native/reserved или свой (не чужой reserved)."
  @spec validate_kind!(atom(), atom()) :: :ok

  def validate_kind!(native, kind)
      when is_atom(native) and is_atom(kind) do
    cond do
      kind == native ->
        :ok

      kind in reserved_kinds() ->
        raise ArgumentError,
              "kind #{inspect(kind)} is a builtin kind; use native #{inspect(native)} or a custom kind"

      true ->
        :ok
    end
  end

  @doc """
  Модуль объявлен через `use Prim` (есть `__domain_kind__/0` и `value/1`).

  При необходимости загружает модуль: `function_exported?/3` отвечает только
  про уже загруженный код (lazy loading, purge при code reload).
  """
  @spec prim?(module()) :: boolean()

  def prim?(mod) when is_atom(mod) do
    (:erlang.module_loaded(mod) or match?({:module, _}, Code.ensure_compiled(mod))) and
      function_exported?(mod, :__domain_kind__, 0) and
      function_exported?(mod, :value, 1)
  end

  @doc "Prim объявлен через `Prim.Compose` (есть `__domain_base__/0`)."
  @spec composed?(module()) :: boolean()

  def composed?(mod) when is_atom(mod) do
    prim?(mod) and function_exported?(mod, :__domain_base__, 0)
  end

  @doc "Рекурсивно достать самое внутреннее не-Prim значение."
  @spec unwrap(struct()) :: term()

  def unwrap(%mod{value: value}) when is_atom(mod) do
    if not prim?(mod) do
      raise ArgumentError, "expected Prim struct, got: #{inspect(mod)}"
    end

    case value do
      %inner{} = nested ->
        if prim?(inner), do: unwrap(nested), else: value

      other ->
        other
    end
  end

  @doc """
  Скрыть сырое значение чувствительного Prim перед записью в `Error.detail`.

  При `sensitive == false` возвращает `raw` как есть. Смысл — не пустить plaintext
  пароля / токена в логи и Sentry через `inspect(%Error{})`.
  """
  @spec redact(term(), boolean()) :: term()

  def redact(raw, false), do: raw
  def redact(raw, true) when is_binary(raw), do: {:redacted, byte_size(raw)}
  def redact(_raw, true), do: :redacted

  @doc false
  @spec wrap_error(module(), String.t(), atom(), String.t(), term()) :: Error.t()

  def wrap_error(module, name, code, reason, detail)
      when is_atom(code) and is_binary(reason) do
    Error.domain(module,
      code: code,
      ns: :prim,
      message: "#{name}: #{reason}",
      detail: detail
    )
  end

  @doc """
  Обернуть ошибку базового Prim: cause-цепочка + склейка message.

  При `sensitive == true` редактируется `detail` **всей** цепочки: базовый Prim может
  быть несенситивным и положить plaintext в свой `detail`, а `inspect(%Error{})` в логах
  и Sentry печатает цепочку целиком.
  """
  @spec wrap_parent(module(), String.t(), Error.t(), term(), boolean()) :: Error.t()

  def wrap_parent(module, name, %Error{} = parent, raw, sensitive)
      when is_binary(name) and is_boolean(sensitive) do
    parent = redact_chain(parent, sensitive)
    parent_message = parent.message || "#{parent.ns}/#{parent.code}"

    Error.domain(module,
      code: parent.code,
      ns: :prim,
      message: "#{name}: #{parent_message}",
      detail: redact(raw, sensitive),
      parent: parent
    )
  end

  # ---

  defp redact_chain(%Error{} = error, false), do: error

  defp redact_chain(%Error{parent: nil} = error, true) do
    %{error | detail: redact(error.detail, true)}
  end

  defp redact_chain(%Error{parent: %Error{} = parent} = error, true) do
    %{error | detail: redact(error.detail, true), parent: redact_chain(parent, true)}
  end

  @doc false
  @spec normalize_ok({:ok, term()} | error()) :: {:ok, term()} | error()

  def normalize_ok({:ok, value}), do: {:ok, value}

  def normalize_ok({:error, {code, detail}} = err)
      when is_atom(code) and is_binary(detail),
      do: err

  def normalize_ok({:error, %Error{}} = err), do: err

  def normalize_ok(other) do
    raise ArgumentError,
          "domain error must be {:error, {code, detail}} or {:error, %Error{}}, got: #{inspect(other)}"
  end

  @doc false
  @spec normalize_validate(:ok | error()) :: :ok | error()

  def normalize_validate(:ok), do: :ok

  def normalize_validate({:error, {code, detail}} = err)
      when is_atom(code) and is_binary(detail),
      do: err

  def normalize_validate({:error, %Error{}} = err), do: err

  def normalize_validate(other) do
    raise ArgumentError,
          "domain error must be {:error, {code, detail}} or {:error, %Error{}}, got: #{inspect(other)}"
  end

  @doc false
  @spec run_mutates(term(), term(), keyword()) :: {:ok, term()} | error()

  def run_mutates(nil, value, _opts), do: {:ok, value}

  def run_mutates(fun, value, opts) when is_function(fun, 2) do
    normalize_mutate(fun.(value, opts))
  end

  def run_mutates(fun, value, _opts) when is_function(fun, 1) do
    normalize_mutate(fun.(value))
  end

  def run_mutates(funs, value, opts) when is_list(funs) do
    Enum.reduce_while(funs, value, fn fun, acc ->
      case run_mutates(fun, acc, opts) do
        {:ok, next} -> {:cont, next}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      next -> {:ok, next}
    end
  end

  # ---

  defp normalize_mutate({:ok, value}), do: {:ok, value}

  defp normalize_mutate({:error, {code, detail}} = err)
       when is_atom(code) and is_binary(detail),
       do: err

  defp normalize_mutate({:error, %Error{}} = err), do: err

  defp normalize_mutate({:error, _} = err) do
    raise ArgumentError,
          "domain error must be {:error, {code, detail}} or {:error, %Error{}}, got: #{inspect(err)}"
  end

  defp normalize_mutate(value), do: {:ok, value}

  @doc false
  @spec run_validates(term(), term(), keyword()) :: :ok | error()

  # Формы те же, что у `custom_mutate` и встроенного `validate:`: `fun/1`, `fun/2`,
  # `{Module, opts}` и список любого из них.
  def run_validates(nil, _value, _opts), do: :ok

  def run_validates({module, module_opts}, value, _opts) when is_atom(module) do
    normalize_validate(module.validate(value, module_opts))
  end

  def run_validates(fun, value, opts) when is_function(fun, 2) do
    normalize_validate(fun.(value, opts))
  end

  def run_validates(fun, value, _opts) when is_function(fun, 1) do
    normalize_validate(fun.(value))
  end

  def run_validates(validators, value, opts) when is_list(validators) do
    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case run_validates(validator, value, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
