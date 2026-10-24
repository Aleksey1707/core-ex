defmodule Core.Prim.UUID do
  @moduledoc """
  Билдер uuid-Prim: генерация (`new/0`), идентификатор из ключа (`from_key/1`) или внешний UUID
  источника и валидация UUID-строки.

  Опции: `name:` (обязательна), `kind:`, `version:` (1 / 4 / 5 / 7 / `:external`; default 4),
  `check_version:` (default `true`), `namespace:` / `scope:` (только и обязательно при
  `version: 5`), `mutate:` / `validate:`, `sensitive:`, `personal:`. Wire-форму (`:full` / `:hex` / `:urn`)
  задаёт профиль кодека, не Prim.

  `version:` задаёт версию для `new/0` и ожидаемую версию для `new/1`; `check_version:
  false` оставляет генерацию, но снимает проверку версии на разборе — для Prim, куда
  приходят чужие идентификаторы.

  `version: 5` — идентификатор из ключа (ADR-0017): `new/0` не генерируется, вместо него —
  приватный `from_key(String.t() | [String.t(), ...])`, который зовёт публичный `from_<key>`
  модуля. id — вложенный UUIDv5: `namespace:` (UUID-строка приложения) → `scope:` (область
  ключа, непустая строка) → части ключа по одной; строка — ключ из одной части.
  `check_version: false` при `version: 5` снимает проверку версии на разборе — для агрегата,
  который переходит на идентификатор из ключа и разбирает прежние случайные id.

  `version: :external` — внешний идентификатор (ADR-0036): UUID источника как есть. Ни `new/0`,
  ни `from_key/1` нет — id не выпускается в обход источника; разбор принимает UUID любой версии.
  `check_version:`, `namespace:` и `scope:` при нём — `CompileError`.

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:`,
  `namespace:` (`Mod.namespace()`) — проверяются в теле модуля;
  остальные опции — литералы.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.UUID",
    native_kind: :uuid,
    optional: ~w(version check_version namespace scope)a,
    expression: ~w(namespace)a

  @versions [1, 4, 5, 7]
  @key_opts ~w(namespace scope)a

  # ===== объявление =====

  @doc "Объявить UUID-Prim (`name:` + опции version)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    type_opts = Keyword.take(opts, ~w(version)a)
    version = Keyword.get(type_opts, :version, 4)

    validate_opts =
      if Keyword.get(opts, :check_version, true) and version != :external,
        do: type_opts,
        else: Keyword.put(type_opts, :version, nil)

    base_opts =
      Prim.Wrapper.base_opts(opts, label()) ++
        [
          cast: quote(do: &Core.Prim.UUID.cast/1),
          validate: quote(do: {Core.Validator.UUID, unquote(Macro.escape(validate_opts))}),
          type_opts: Macro.escape(type_opts),
          value_type: quote(do: String.t())
        ]

    quote do
      use Core.Prim, unquote(base_opts)

      unquote(version_fns(version, opts))

      @doc "Отформатировать UUID (`:full` / `:hex` / `:urn`)."
      @spec format(t(), :full | :hex | :urn) :: String.t()

      def format(%__MODULE__{} = prim, fmt) when fmt in ~w(full hex urn)a do
        Core.Prim.UUID.format(value(prim), fmt)
      end
    end
  end

  @doc false
  @spec namespace!(term()) :: String.t()

  # Опция-выражение `namespace:` (`Mod.namespace()`) — проверка в теле модуля.
  def namespace!(namespace) do
    Prim.Opts.uuid!([namespace: namespace], :namespace, label())
    namespace
  end

  # ---

  defp version_fns(5, opts) do
    quote do
      @uuid_namespace Core.Prim.UUID.namespace!(unquote(Keyword.fetch!(opts, :namespace)))
      @uuid_scope unquote(Keyword.fetch!(opts, :scope))

      @spec from_key(String.t() | [String.t(), ...]) :: t()

      # Одна clause: потребитель зовёт одну из форм, и clause другой дала бы ему «never used»,
      # а рекурсия строки в список теряет сужение результата `new!/1`.
      defp from_key(key) when is_binary(key) or (is_list(key) and key != []) do
        new!(Core.Prim.UUID.from_key(@uuid_namespace, @uuid_scope, key))
      end
    end
  end

  defp version_fns(:external, _opts), do: nil

  defp version_fns(version, _opts) do
    quote do
      @doc "Сгенерировать новый UUID."
      @spec new() :: t()

      def new, do: new!(Core.Prim.UUID.generate(unquote(version)))
    end
  end

  # ===== опции =====

  @doc false
  @spec versions() :: [pos_integer()]

  def versions, do: @versions

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.allowed!(opts, :version, [nil, :external | @versions], label())
    Prim.Opts.boolean!(opts, ~w(check_version)a, label())
    version = Keyword.get(opts, :version, 4)
    check_version_opt!(opts, version)
    key_opts!(opts, version)
    Prim.Opts.non_empty_string!(opts, ~w(scope)a, label())
  end

  # ---

  defp check_version_opt!(opts, :external) do
    if Keyword.has_key?(opts, :check_version) do
      Helper.Opts.reject!(
        "#{label()}: check_version",
        "допустима только при version: 1 / 4 / 5 / 7 — разбор внешнего UUID версию не проверяет"
      )
    end

    :ok
  end

  defp check_version_opt!(_opts, _version), do: :ok

  defp key_opts!(opts, 5) do
    case Enum.find(@key_opts, &is_nil(Keyword.get(opts, &1))) do
      nil ->
        :ok

      key ->
        Helper.Opts.reject!(
          "#{label()}: #{key}",
          "обязательна при version: 5 — идентификатор из ключа считается от namespace приложения и области ключа"
        )
    end
  end

  defp key_opts!(opts, version) do
    case Enum.find(@key_opts, &Keyword.has_key?(opts, &1)) do
      nil ->
        :ok

      key ->
        Helper.Opts.reject!("#{label()}: #{key}", "допустима только при version: 5 — #{keyless_reason(version)}")
    end
  end

  defp keyless_reason(:external), do: "внешний UUID приходит от источника, а не считается от ключа"
  defp keyless_reason(_version), do: "генерируемый UUID ключа не знает"

  # ===== значение =====

  @doc "Сгенерировать UUID v4 (дефолтная версия)."
  @spec generate() :: String.t()

  def generate, do: generate(4)

  @doc false
  @spec generate(pos_integer() | nil) :: String.t()

  # Домен версии сужен на компиляции (`validate_opts!/1`): defensive-clause с `raise`
  # только расширила бы его обратно.
  def generate(nil), do: generate(4)
  def generate(4), do: UUID.uuid4()
  def generate(1), do: UUID.uuid1()
  def generate(7), do: UUIDv7.generate()

  @doc false
  @spec from_key(String.t(), String.t(), String.t() | [String.t(), ...]) :: String.t()

  def from_key(namespace, scope, key) when is_binary(key), do: from_key(namespace, scope, [key])

  def from_key(namespace, scope, [_ | _] = parts) when is_binary(namespace) and is_binary(scope) do
    Enum.reduce(parts, UUID.uuid5(namespace, scope), &UUID.uuid5(&2, &1))
  end

  @doc """
  Отформатировать UUID-строку (`:full` / `:hex` / `:urn`).

  Каноническая форма — та, в которой Prim хранит значение (её отдаёт `cast/1`), — переводится
  срезкой: `:full` возвращается как есть, остальные собираются из её же кусков. Разбор строки
  в 16 байт и обратная сборка библиотекой — самая дорогая часть дампа uuid на read-пути,
  а из канонической формы результат получается копированием.

  Прочие формы (hex, urn, верхний регистр) приводит библиотека.
  """
  @spec format(String.t(), :full | :hex | :urn) :: String.t()

  def format(uuid, fmt) when is_binary(uuid) and fmt in ~w(full hex urn)a do
    if canonical?(uuid),
      do: from_canonical(uuid, fmt),
      else: convert(uuid, fmt)
  end

  @doc false
  @spec cast(term()) :: Result.t(String.t(), {:invalid_uuid, String.t()})

  def cast(value) when is_binary(value) do
    {:ok, normalize(value)}
  rescue
    # Каноническую строку `cast/1` не разбирает вовсе, неканоническую — один раз через
    # `string_to_binary!/1`; версию и формат проверяет `Core.Validator.UUID` своим
    # `UUID.info/1` уже на нормализованном значении.
    ArgumentError -> {:error, {:invalid_uuid, "невалидное значение"}}
  end

  def cast(_), do: {:error, {:invalid_uuid, "невалидное значение"}}

  # ---

  defp normalize(uuid) do
    if canonical?(uuid), do: uuid, else: convert(uuid, :full)
  end

  defp convert(uuid, fmt) do
    uuid
    |> UUID.string_to_binary!()
    |> UUID.binary_to_string!(to_uuid_format(fmt))
  end

  defp from_canonical(uuid, :full), do: uuid
  defp from_canonical(uuid, :urn), do: "urn:uuid:" <> uuid

  defp from_canonical(
         <<a::binary-size(8), ?-, b::binary-size(4), ?-, c::binary-size(4), ?-, d::binary-size(4), ?-,
           e::binary-size(12)>>,
         :hex
       ) do
    a <> b <> c <> d <> e
  end

  # Каноническая форма: 36 символов, дефисы на своих местах, шестнадцатеричные цифры
  # в нижнем регистре. Верхний регистр канону не соответствует — его нормализует `cast/1`.
  defp canonical?(
         <<a::binary-size(8), ?-, b::binary-size(4), ?-, c::binary-size(4), ?-, d::binary-size(4), ?-,
           e::binary-size(12)>>
       ) do
    lower_hex?(a) and lower_hex?(b) and lower_hex?(c) and lower_hex?(d) and lower_hex?(e)
  end

  defp canonical?(_uuid), do: false

  defp lower_hex?(<<>>), do: true

  defp lower_hex?(<<char, rest::binary>>) when char in ?0..?9 or char in ?a..?f do
    lower_hex?(rest)
  end

  defp lower_hex?(_binary), do: false

  defp to_uuid_format(:full), do: :default
  defp to_uuid_format(:hex), do: :hex
  defp to_uuid_format(:urn), do: :urn
end
