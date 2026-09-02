defmodule Core.Prim.UUID do
  @moduledoc """
  Билдер uuid-Prim: генерация (`new/0`) и валидация UUID-строки.

  Опции: `name:` (обязательна), `kind:`, `version:` (1 / 4 / 7; default 4),
  `mutate:` / `validate:`, `sensitive:`. Wire-форму (`:full` / `:hex` / `:urn`)
  задаёт профиль кодека, не Prim.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Validator

  @native_kind :uuid
  @required_keys ~w(name)a
  @optional_keys ~w(kind version check_version mutate validate sensitive)a

  @doc "Объявить UUID-Prim (`name:` + опции version)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Prim.UUID.required_keys(),
        Core.Prim.UUID.optional_keys(),
        "Prim.UUID"
      )

      native = Core.Prim.UUID.native_kind()
      kind = Keyword.get(opts, :kind, native)
      Prim.validate_kind!(native, kind)

      type_opts = Keyword.take(opts, ~w(version)a)
      version = Keyword.get(type_opts, :version, 4)
      check_version = Keyword.get(opts, :check_version, true)

      validate_opts =
        if check_version do
          type_opts
        else
          Keyword.put(type_opts, :version, nil)
        end

      use Prim,
        cast: &Core.Prim.UUID.cast/1,
        validate: {Validator.UUID, validate_opts},
        custom_mutate: Keyword.get(opts, :mutate),
        custom_validate: Keyword.get(opts, :validate),
        name: Keyword.fetch!(opts, :name),
        kind: kind,
        type_opts: type_opts,
        sensitive: Keyword.get(opts, :sensitive, false)

      @uuid_version version

      @doc "Сгенерировать новый UUID."
      @spec new() :: t()

      def new, do: new!(Core.Prim.UUID.generate(@uuid_version))

      @doc "Отформатировать UUID (`:full` / `:hex` / `:urn`)."
      @spec format(t(), :full | :hex | :urn) :: String.t()

      def format(%__MODULE__{} = prim, fmt) when fmt in ~w(full hex urn)a do
        Core.Prim.UUID.format(value(prim), fmt)
      end
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec native_kind() :: atom()

  def native_kind, do: @native_kind

  @doc "Сгенерировать UUID v4 (дефолтная версия)."
  @spec generate() :: String.t()

  def generate, do: generate(4)

  @doc false
  @spec generate(pos_integer() | nil) :: String.t()

  def generate(nil), do: generate(4)
  def generate(4), do: UUID.uuid4()
  def generate(1), do: UUID.uuid1()
  def generate(7), do: UUIDv7.generate()

  def generate(version) do
    raise ArgumentError, "unsupported UUID version for generation: #{inspect(version)}"
  end

  @doc "Отформатировать UUID-строку (`:full` / `:hex` / `:urn`)."
  @spec format(String.t(), :full | :hex | :urn) :: String.t()

  def format(uuid, fmt) when is_binary(uuid) and fmt in ~w(full hex urn)a do
    uuid
    |> UUID.string_to_binary!()
    |> UUID.binary_to_string!(to_uuid_format(fmt))
  end

  # ---

  defp to_uuid_format(:full), do: :default
  defp to_uuid_format(:hex), do: :hex
  defp to_uuid_format(:urn), do: :urn

  @doc false
  @spec cast(term()) :: {:ok, String.t()} | {:error, {:invalid_uuid, String.t()}}

  def cast(value) when is_binary(value) do
    case UUID.info(value) do
      {:ok, _} -> {:ok, format(value, :full)}
      {:error, _} -> {:error, {:invalid_uuid, "невалидное значение"}}
    end
  end

  def cast(_), do: {:error, {:invalid_uuid, "невалидное значение"}}
end
