defmodule Core.Labels.Event do
  @moduledoc """
  Название события — подпись вида события для человека (ADR-0063).

  Подключается в модуле события после `use Core.Es.Event`:

      use Core.Es.Event,
        aggregate_id: MyApp.Domain.Sales.Account.ID,
        by: MyApp.Domain.Sales.Values.UserID,
        payload: Payload

      use Core.Labels.Event, title: "Счёт переименован"

  `title:` обязательна: одна на событие и без подстановок — переменное живёт в сведениях
  (`Core.Labels.Details`). Нагрузку-struct подписывает она сама (`Core.Labels.Fields`), а у
  нагрузки-Prim своих полей нет, и её подпись — `payload:` события:

      use Core.Es.Event,
        aggregate_id: MyApp.Domain.Sales.Account.ID,
        by: MyApp.Domain.Sales.Values.UserID,
        payload: MyApp.Domain.Sales.Account.Name

      use Core.Labels.Event,
        title: "Счёт переименован",
        payload: "Название"

  Сборку ломают: модуль без `use Core.Es.Event`, пустое или не строковое название, нагрузка-Prim
  без `payload:`, `payload:` у события без нагрузки или с нагрузкой-struct'ом и нагрузка-struct
  без `use Core.Labels.Fields`.

  Макрос занимает в модуле события имена `__label_title__/0` и `__label_payload__/0`.
  """

  alias Core.Labels.Check

  @label "Labels.Event"
  @required_keys ~w(title)a
  @optional_keys ~w(payload)a

  # ===== объявление =====

  @doc "Объявить название события (`title:`) и подпись нагрузки-Prim (`payload:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Core.Helper.Opts.validate!(
        opts,
        Core.Labels.Event.required_keys(),
        Core.Labels.Event.optional_keys(),
        "Labels.Event"
      )

      {title, payload} = Core.Labels.Event.declaration!(__MODULE__, opts)

      @label_title title
      @label_payload payload
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
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec declaration!(module(), keyword()) :: {String.t(), String.t() | nil}

  def declaration!(module, opts) when is_atom(module) and is_list(opts) do
    if not Module.defines?(module, {:__es_payload__, 0}) do
      raise CompileError,
        description: "#{where(module)}: не событие: `use Core.Labels.Event` подключается после `use Core.Es.Event`"
    end

    title = Check.text!(Keyword.fetch!(opts, :title), "#{where(module)}: title")

    case Keyword.fetch(opts, :payload) do
      {:ok, payload} -> {title, Check.text!(payload, "#{where(module)}: payload")}
      :error -> {title, nil}
    end
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
    if function_exported?(payload, :__label_fields__, 0),
      do: :ok,
      else: fail!(env, "нагрузка-struct #{inspect(payload)} без `use Core.Labels.Fields`")
  end

  defp fail!(env, message) do
    raise CompileError, description: "#{where(env.module)}: #{message}", file: env.file, line: env.line
  end

  # ===== общее =====

  defp where(module), do: "#{@label} #{inspect(module)}"
end
