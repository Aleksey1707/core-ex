defmodule Core.Prim do
  @moduledoc """
  Билдер value object: `%Mod{value:}` + конвейер `cast → mutate → custom_mutate →
  validate → custom_validate`.

  Опции `use`: обязательные `cast:`, `name:`, `kind:`; необязательные `mutate:`, `validate:`,
  `custom_mutate:`, `custom_validate:`, `type_opts:`, `pipeline_opts:`, `sensitive:`, `personal:`,
  `value_type:` (AST типа значения, default `term()`).

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:` (`first_line(@moduledoc)`),
  `cast:`, `mutate:`, `validate:`, `custom_mutate:`, `custom_validate:`, `type_opts:`,
  `pipeline_opts:` — проверяются в теле модуля; `value_type:` — AST типа, его подставляет в `@type t`
  компилятор типов. Остальные (`kind:`, `sensitive:`, `personal:`) — литералы: атрибут или вызов в
  них — `CompileError` «ожидается литерал».

  Типизированные обёртки — `Prim.String` / `Integer` / `Decimal` / `UUID` / `DateTime` /
  `Date` / `Compose`.

  Генерирует `new/1`, `new!/1`, `value/1`, `name/0`, `__domain_kind__/0`,
  `__domain_type_opts__/0`, `__domain_sensitive__/0`, `__domain_personal__/0`. `sensitive: true`
  и `personal: true` скрывают значение от `inspect/1` и редактируют его в `Error.detail`; флаги
  независимы, `personal: true` read-путь (`Core.View`, Redump) не запрещает.

  Формы шагов конвейера:

  | Опция | Формы |
  |---|---|
  | `cast:` | `fun/1`, `fun/2` (второй аргумент — `pipeline_opts`) |
  | `mutate:`, `custom_mutate:` | `{Module, opts}` (`Core.Mutator`), `fun/1`, `fun/2` или список любой из форм |
  | `validate:`, `custom_validate:` | `{Module, opts}` (`Core.Validator`), `fun/1`, `fun/2` или список любой из форм |

  `type_opts:` — опции **типа** (`precision`, `tz`, границы); их отдаёт
  `__domain_type_opts__/0` и получают validate-шаги. `pipeline_opts:` (default —
  `type_opts`) получают cast/mutate-шаги: обёртке нужны там и опции обработки
  (`trim`, `sec_max_len`), которым в контракте типа места нет.
  """

  alias Core.Error
  alias Core.Helper
  alias Core.Mutator
  alias Core.Result
  alias Core.Validator

  require Error

  @label "Prim"
  @required_keys ~w(cast name kind)a
  @optional_keys ~w(mutate validate custom_mutate custom_validate type_opts pipeline_opts sensitive personal)a ++
                   ~w(value_type)a
  @expression_keys ~w(cast name mutate validate custom_mutate custom_validate type_opts pipeline_opts value_type)a

  # ===== объявление =====

  @doc "Объявить доменный Prim (`cast` / `name` / `kind` + опциональные mutate/validate)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    Helper.Opts.atom!(opts, :kind, @label)
    flags!(opts)

    value_type = Keyword.get(opts, :value_type, quote(do: term()))

    quote do
      @cast Core.Prim.cast!(unquote(opts[:cast]))
      @name Core.Helper.Opts.binary_value!(unquote(opts[:name]), :name, unquote(@label))
      @domain_kind unquote(opts[:kind])
      @mutate unquote(steps_ast(opts, :mutate))
      @validate unquote(steps_ast(opts, :validate))
      @custom_mutate unquote(steps_ast(opts, :custom_mutate))
      @custom_validate unquote(steps_ast(opts, :custom_validate))
      @type_opts unquote(keyword_ast(opts, :type_opts, []))
      @pipeline_opts unquote(keyword_ast(opts, :pipeline_opts, quote(do: @type_opts)))
      @sensitive unquote(Keyword.get(opts, :sensitive, false))
      @personal unquote(Keyword.get(opts, :personal, false))
      @redacted @sensitive or @personal

      @enforce_keys ~w(value)a

      if @redacted do
        @derive {Inspect, except: ~w(value)a}
      end

      defstruct ~w(value)a

      @type t :: %__MODULE__{value: unquote(value_type)}

      @doc "Создать Prim из raw."
      @spec new(term()) :: Core.Result.t(t())

      def new(raw) do
        with {:ok, value} <- Core.Prim.run_cast(@cast, raw, @pipeline_opts),
             {:ok, value} <-
               Core.Prim.run_mutates(@mutate, value, @pipeline_opts),
             {:ok, value} <-
               Core.Prim.run_mutates(@custom_mutate, value, @pipeline_opts),
             :ok <-
               Core.Prim.run_validates(@validate, value, @type_opts),
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
               Core.Prim.redact(raw, @redacted)
             )}

          {:error, %Error{} = parent} ->
            {:error, Core.Prim.wrap_parent(__MODULE__, @name, parent, raw, @redacted)}
        end
      end

      @doc "Создать Prim; при ошибке — raise."
      @spec new!(term()) :: t()

      unquote(
        quote generated: true do
          def new!(raw) do
            case new(raw) do
              {:ok, %__MODULE__{} = prim} -> prim
              {:error, %Error{} = error} -> raise Core.Exc, error
            end
          end
        end
      )

      @doc "Достать внутреннее значение."
      @spec value(t()) :: unquote(value_type)

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

      @doc "Prim объявлен персональным (`personal: true`)."
      @spec __domain_personal__() :: boolean()

      def __domain_personal__, do: @personal

      @doc """
      Опции типа, с которыми объявлен Prim (`precision`, `tz`, границы).

      Нужны потребителям, которые приводят к wire значение **без** Prim-обёртки
      (`Core.Codec.coerce/2` на read-пути): без них формат зависел бы только от kind,
      и значение из колонки разошлось бы с тем же значением, прошедшим через Prim.
      """
      @spec __domain_type_opts__() :: keyword()

      def __domain_type_opts__, do: @type_opts
    end
  end

  @doc false
  @spec cast!(term()) :: cast_spec()

  def cast!(cast) when is_function(cast, 1) or is_function(cast, 2), do: cast
  def cast!(cast), do: Helper.Opts.reject!("#{@label}: cast", "ожидается fun/1 или fun/2, получено #{inspect(cast)}")

  @doc false
  @spec steps!(term(), atom(), String.t()) :: mutate_spec() | validate_spec() | nil

  def steps!(steps, key, label) when is_atom(key) and is_binary(label) do
    if steps?(steps) do
      steps
    else
      expected = "{Module, opts}, fun/1, fun/2 или их список"
      Helper.Opts.reject!("#{label}: #{key}", "ожидается #{expected}, получено #{inspect(steps)}")
    end
  end

  @doc false
  @spec keyword!(term(), atom()) :: keyword()

  def keyword!(opts, key) when is_atom(key) do
    if Keyword.keyword?(opts),
      do: opts,
      else: Helper.Opts.reject!("#{@label}: #{key}", "ожидается keyword, получено #{inspect(opts)}")
  end

  # ---

  defp flags!(opts) do
    for {key, value} <- Keyword.take(opts, ~w(sensitive personal)a), not is_boolean(value) do
      Helper.Opts.reject!("#{@label}: #{key}", "ожидается true или false, получено #{inspect(value)}")
    end
  end

  defp steps_ast(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, steps} -> quote(do: Core.Prim.steps!(unquote(steps), unquote(key), unquote(@label)))
      :error -> nil
    end
  end

  defp keyword_ast(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> quote(do: Core.Prim.keyword!(unquote(value), unquote(key)))
      :error -> default
    end
  end

  defp steps?(nil), do: true
  defp steps?(steps) when is_list(steps), do: Enum.all?(steps, &step?/1)
  defp steps?(step), do: step?(step)

  defp step?({module, opts}) when is_atom(module) and is_list(opts), do: true
  defp step?(fun) when is_function(fun, 1) or is_function(fun, 2), do: true
  defp step?(_step), do: false

  # ===== сведения и ошибки =====

  @type reason :: {atom(), String.t()} | Error.t()
  @type error :: {:error, reason()}
  @type cast_result :: Result.t(term(), reason())
  @type cast_spec :: (term() -> cast_result()) | (term(), keyword() -> cast_result())
  @type mutate_spec :: Mutator.mutate_spec() | [Mutator.mutate_spec()]
  @type validate_spec :: Validator.validate_spec() | [Validator.validate_spec()]

  @native_kinds ~w(uuid datetime date decimal integer string)a
  @composite_kind :composite

  @doc "Native kinds доменных Prim-обёрток."
  @spec native_kinds() :: [atom()]

  def native_kinds, do: @native_kinds

  @doc "Зарезервированные kinds: native + `:composite`."
  @spec reserved_kinds() :: [atom()]

  def reserved_kinds, do: @native_kinds ++ [@composite_kind]

  @doc """
  Проверка `kind:` обёртки: native/reserved или свой (не чужой reserved).

  Чужой встроенный kind — `CompileError` «<label>: kind: …».
  """
  @spec validate_kind!(atom(), atom(), String.t()) :: :ok

  def validate_kind!(native, kind, label)
      when is_atom(native) and is_atom(kind) and is_binary(label) do
    if kind != native and kind in reserved_kinds() do
      Helper.Opts.reject!(
        "#{label}: kind",
        "#{inspect(kind)} — встроенный; используйте нативный #{inspect(native)} либо свой kind"
      )
    end

    :ok
  end

  @doc """
  Модуль объявлен через `use Prim` (есть `__domain_kind__/0` и `value/1`).

  При необходимости загружает модуль (`Core.Helper.Module.exports?/3`).
  """
  @spec prim?(module()) :: boolean()

  def prim?(mod) when is_atom(mod) do
    Helper.Module.exports?(mod, :__domain_kind__, 0) and Helper.Module.exports?(mod, :value, 1)
  end

  @doc false
  @spec declared?(module()) :: boolean()

  def declared?(mod) when is_atom(mod), do: Module.defines?(mod, {:__domain_kind__, 0})

  @doc "Prim объявлен через `Prim.Compose` (есть `__domain_base__/0`)."
  @spec composed?(module()) :: boolean()

  def composed?(mod) when is_atom(mod) do
    prim?(mod) and Helper.Module.exports?(mod, :__domain_base__, 0)
  end

  @doc """
  Leaf-примитив Prim `mod` — последнее звено `chain/1`: сам `mod`, если он не композит.

  `mod` — Prim; не Prim — `MatchError`.
  """
  @spec leaf(module()) :: module()

  def leaf(mod) when is_atom(mod) do
    [_ | _] = chain = chain(mod)

    List.last(chain)
  end

  # На звено — одна проверка `prim?/1`, без `composed?/1`: read-путь `Core.Codec.coerce/2`
  # строит цепочку на каждое поле каждой строки.
  @doc """
  Цепочка `Prim.Compose` от `mod` до leaf-примитива: `[Mod, Base, …, Leaf]`; `[]` — не Prim.

  У leaf-примитива цепочка из него одного.
  """
  @spec chain(module()) :: [module()]

  def chain(mod) when is_atom(mod) do
    cond do
      not prim?(mod) -> []
      Helper.Module.exports?(mod, :__domain_base__, 0) -> [mod | chain(mod.__domain_base__())]
      true -> [mod]
    end
  end

  @doc "Рекурсивно достать самое внутреннее не-Prim значение."
  @spec unwrap(struct()) :: term()

  def unwrap(%mod{value: value}) when is_atom(mod) do
    if not prim?(mod) do
      raise ArgumentError, "ожидается struct Prim, получено: #{inspect(mod)}"
    end

    case value do
      %inner{} = nested ->
        if prim?(inner), do: unwrap(nested), else: value

      other ->
        other
    end
  end

  @doc """
  Скрыть сырое значение чувствительного или персонального Prim перед записью в `Error.detail`.

  При `redacted == false` возвращает `raw` как есть. Смысл — не пустить plaintext
  пароля / токена / ПДн в логи и Sentry через `inspect(%Error{})`.
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

  При `redacted == true` редактируется `detail` **всей** цепочки: базовый Prim может
  быть обычным и положить plaintext в свой `detail`, а `inspect(%Error{})` в логах
  и Sentry печатает цепочку целиком.
  """
  @spec wrap_parent(module(), String.t(), Error.t(), term(), boolean()) :: Error.t()

  def wrap_parent(module, name, %Error{} = parent, raw, redacted)
      when is_binary(name) and is_boolean(redacted) do
    parent = redact_chain(parent, redacted)
    parent_message = to_string(parent)

    Error.domain(module,
      code: parent.code,
      ns: :prim,
      message: "#{name}: #{parent_message}",
      detail: redact(raw, redacted),
      parent: parent
    )
  end

  @doc false
  @spec redact_for(module(), Error.t()) :: Error.t()

  # `detail` всей cause-цепочки по флагам Prim `mod` (`sensitive:` или `personal:`): ошибку базы
  # `Core.Codec.load_composite/3` отдаёт вместо ошибки композита, и редактирует флаг композита.
  def redact_for(mod, %Error{} = error) when is_atom(mod) do
    redact_chain(error, mod.__domain_sensitive__() or mod.__domain_personal__())
  end

  @doc false
  @spec redact_error(Error.t()) :: Error.t()

  # `detail` всей cause-цепочки без оглядки на флаги Prim: ошибка загрузки ПДн-поля нагрузки события
  # (`subject:`) редактируется, какого бы вида ни было поле.
  def redact_error(%Error{} = error), do: redact_chain(error, true)

  # ---

  defp redact_chain(%Error{} = error, false), do: error

  defp redact_chain(%Error{parent: nil} = error, true) do
    %{error | detail: redact(error.detail, true)}
  end

  defp redact_chain(%Error{parent: %Error{} = parent} = error, true) do
    %{error | detail: redact(error.detail, true), parent: redact_chain(parent, true)}
  end

  # ===== прогон шагов =====

  @doc false
  @spec normalize_ok(cast_result()) :: cast_result()

  def normalize_ok({:ok, value}), do: {:ok, value}

  def normalize_ok({:error, {code, detail}} = err)
      when is_atom(code) and is_binary(detail),
      do: err

  def normalize_ok({:error, %Error{}} = err), do: err

  def normalize_ok(other) do
    raise ArgumentError,
          "доменная ошибка: ожидается {:error, {code, detail}} или {:error, %Error{}}, получено: #{inspect(other)}"
  end

  @doc false
  @spec normalize_validate(Result.unit(reason())) :: Result.unit(reason())

  def normalize_validate(:ok), do: :ok

  def normalize_validate({:error, {code, detail}} = err)
      when is_atom(code) and is_binary(detail),
      do: err

  def normalize_validate({:error, %Error{}} = err), do: err

  def normalize_validate(other) do
    raise ArgumentError,
          "доменная ошибка: ожидается {:error, {code, detail}} или {:error, %Error{}}, получено: #{inspect(other)}"
  end

  @doc false
  @spec check_byte_limit(binary(), pos_integer() | nil, atom()) :: Result.unit(reason())

  # Граница по байтам, а не по символам или цифрам: любой разбор ввода (`String.valid?/1`,
  # `Integer.parse/1`, `Decimal.new/1`) обходит его целиком, то есть делает ровно ту
  # работу, от которой security-лимит должен защищать. Поэтому лимит — первый шаг `cast`.
  def check_byte_limit(_value, nil, _code), do: :ok

  def check_byte_limit(value, limit, code) when is_binary(value) and is_integer(limit) do
    if byte_size(value) <= limit,
      do: :ok,
      else: {:error, {code, "невалидное значение"}}
  end

  @doc false
  @spec run_cast(cast_spec(), term(), keyword()) :: cast_result()

  # Обёртке, которой для cast нужны опции (байтовая отсечка `Prim.String`), передаётся
  # `fun/2`; остальным хватает `fun/1`.
  def run_cast(fun, raw, opts) when is_function(fun, 2), do: normalize_ok(fun.(raw, opts))
  def run_cast(fun, raw, _opts) when is_function(fun, 1), do: normalize_ok(fun.(raw))

  @doc false
  @spec run_mutates(mutate_spec(), term(), keyword()) :: cast_result()

  def run_mutates(nil, value, _opts), do: {:ok, value}

  def run_mutates({module, module_opts}, value, _opts) when is_atom(module) do
    normalize_mutate(Mutator.run({module, module_opts}, value, []))
  end

  def run_mutates(fun, value, opts) when is_function(fun, 1) or is_function(fun, 2) do
    normalize_mutate(Mutator.run(fun, value, opts))
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

  @doc false
  @spec run_validates(validate_spec(), term(), keyword()) :: Result.unit(reason())

  def run_validates(nil, _value, _opts), do: :ok

  def run_validates({module, module_opts}, value, _opts) when is_atom(module) do
    normalize_validate(Validator.run({module, module_opts}, value, []))
  end

  def run_validates(fun, value, opts) when is_function(fun, 1) or is_function(fun, 2) do
    normalize_validate(Validator.run(fun, value, opts))
  end

  def run_validates(validators, value, opts) when is_list(validators) do
    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case run_validates(validator, value, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # ---

  defp normalize_mutate({:ok, value}), do: {:ok, value}

  defp normalize_mutate({:error, {code, detail}} = err)
       when is_atom(code) and is_binary(detail),
       do: err

  defp normalize_mutate({:error, %Error{}} = err), do: err

  defp normalize_mutate({:error, _} = err) do
    raise ArgumentError,
          "доменная ошибка: ожидается {:error, {code, detail}} или {:error, %Error{}}, получено: #{inspect(err)}"
  end

  defp normalize_mutate(value), do: {:ok, value}
end
