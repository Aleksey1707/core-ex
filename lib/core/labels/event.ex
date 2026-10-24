defmodule Core.Labels.Event do
  @moduledoc """
  Название события — подпись вида события для человека (ADR-0063).

  Подключается в модуле события после `use Core.Es.Event`:

      use Core.Es.Event,
        family: MyApp.Domain.Sales.Account.Event,
        payload: Payload

      use Core.Labels.Event, title: "Счёт переименован"

  `title:` обязательна: одна на событие и без подстановок — переменное живёт в сведениях
  (`Core.Labels.Details`). Нагрузку-struct подписывает она сама (`Core.Labels.Fields`), а у
  нагрузки-Prim своих полей нет, и её подпись — `payload:` события:

      use Core.Es.Event,
        family: MyApp.Domain.Sales.Account.Event,
        payload: MyApp.Domain.Sales.Account.Name

      use Core.Labels.Event,
        title: "Счёт переименован",
        payload: "Название"

  Опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов функции в
  опции — `CompileError` «ожидается литерал».

  Сборку ломают: модуль без `use Core.Es.Event`, пустое или не строковое название, нагрузка-Prim
  без `payload:`, `payload:` у события без нагрузки или с нагрузкой-struct'ом и нагрузка-struct
  без `use Core.Labels.Fields`.

  Макрос занимает в модуле события имена `__label_title__/0` и `__label_payload__/0`.
  """

  alias Core.Helper
  alias Core.Labels.Check
  alias Core.Labels.Fields

  @label "Labels.Event"
  @required_keys ~w(title)a
  @optional_keys ~w(payload)a
  @expression_keys []

  # ===== объявление =====

  @doc "Объявить название события (`title:`) и подпись нагрузки-Prim (`payload:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    title = Check.text!(opts[:title], "#{@label}: title")
    payload = if Keyword.has_key?(opts, :payload), do: Check.text!(opts[:payload], "#{@label}: payload")

    quote do
      Core.Labels.Event.host!(__MODULE__)

      @label_title unquote(title)
      @label_payload unquote(payload)
      @after_compile Core.Labels.Event

      @doc false
      @spec __label_title__() :: String.t()

      def __label_title__, do: @label_title

      @doc false
      @spec __label_payload__() :: String.t() | nil

      def __label_payload__, do: @label_payload
    end
  end

  @doc false
  @spec host!(module()) :: :ok

  def host!(module) when is_atom(module) do
    if Core.Es.Event.declared?(module),
      do: :ok,
      else: Helper.Opts.reject!(@label, "не событие: `use Core.Labels.Event` подключается после `use Core.Es.Event`")
  end

  # ===== проверка нагрузки =====

  # Модуль нагрузки известен только из `__es_payload__/0` собранного события.
  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok

  def __after_compile__(env, _bytecode) do
    module = env.module
    payload = module.__es_payload__()

    case {payload_kind(payload), module.__label_payload__()} do
      {:prim, label} when is_binary(label) ->
        :ok

      {:none, nil} ->
        :ok

      {:struct, nil} ->
        ensure_fields!(env, payload)

      {:prim, nil} ->
        fail!(env, "нагрузка-Prim без подписи `payload:`")

      {:none, _label} ->
        fail!(env, "`payload:` у события без нагрузки")

      {:struct, _label} ->
        fail!(env, "`payload:` у нагрузки-struct'а — её поля подписывает `use Core.Labels.Fields`")
    end
  end

  # ---

  defp payload_kind(nil), do: :none

  defp payload_kind(payload) when is_atom(payload) do
    if Core.Prim.prim?(payload), do: :prim, else: :struct
  end

  defp ensure_fields!(env, payload) do
    if Fields.labelled?(payload),
      do: :ok,
      else: fail!(env, "нагрузка-struct #{inspect(payload)} без `use Core.Labels.Fields`")
  end

  defp fail!(env, message) do
    raise CompileError, description: "#{@label} #{inspect(env.module)}: #{message}", file: env.file, line: env.line
  end
end
