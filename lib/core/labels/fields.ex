defmodule Core.Labels.Fields do
  @moduledoc """
  Подписи полей struct'а нагрузки события — решение по каждому полю (ADR-0063).

  Подключается в нагрузке `Core.Es.Event.Payload` после её `use`:

      defmodule Payload do
        use Core.Es.Event.Payload,
          fields: [
            name: [prim: MyApp.Domain.Sales.Account.Name],
            limit: [prim: MyApp.Domain.Sales.Account.Limit, optional: true],
            source: [type: :string]
          ]

        use Core.Labels.Fields,
          labels: [
            name: "Название",
            limit: "Лимит",
            source: :hidden
          ]
      end

  Решение по полю — подпись (непустая строка) или `:hidden`: поле в сведения не попадает. Вид поля
  в сведениях (`Core.Labels.Details`) берётся из спеки нагрузки, в объявлении подписей его нет.

  Полнота проверяется на `@after_compile`, где уже есть struct и спека нагрузки. Сборку ломают:
  поле без решения, подпись поля, которого нет в struct'е, повтор поля, пустая подпись, подпись у
  свободной map'ы (`type: :map`) и `use` не после `use Core.Es.Event.Payload`.

  Макрос занимает в модуле нагрузки имя `__label_fields__/0`.
  """

  alias Core.Codec.Plugin
  alias Core.Labels.Check

  @typedoc "Решение по полю: подпись или скрыто."
  @type label :: String.t() | :hidden

  @label "Labels.Fields"
  @required_keys ~w(labels)a
  @optional_keys []

  # ===== объявление =====

  @doc "Объявить решение по каждому полю нагрузки (`labels:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Core.Helper.Opts.validate!(
        opts,
        Core.Labels.Fields.required_keys(),
        Core.Labels.Fields.optional_keys(),
        "Labels.Fields"
      )

      @label_fields Core.Labels.Fields.labels!(__MODULE__, Keyword.fetch!(opts, :labels))
      @after_compile Core.Labels.Fields

      @doc false
      @spec __label_fields__() :: [{atom(), Core.Labels.Fields.label()}]

      def __label_fields__, do: @label_fields
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec labels!(module(), term()) :: [{atom(), label()}]

  def labels!(module, labels) when is_atom(module) do
    if not Module.defines?(module, {:__es_payload_fields__, 0}) do
      raise CompileError,
        description:
          "#{where(module)} — не нагрузка: `use Core.Labels.Fields` подключается после `use Core.Es.Event.Payload`"
    end

    where = "#{where(module)}: labels:"

    for {field, label} <- Check.keyword!(labels, where), do: {field, label!(label, "#{where} поле #{field}")}
  end

  # ---

  defp label!(:hidden, _where), do: :hidden
  defp label!(text, where), do: Check.text!(text, where)

  # ===== проверка полноты =====

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok

  def __after_compile__(env, _bytecode) do
    module = env.module
    labels = module.__label_fields__()
    fields = for {name, _spec, _optional?, _wire, _default} <- module.__es_payload_fields__(), do: name
    labelled = Keyword.keys(labels)

    ensure_none!(env, fields -- labelled, "поля без подписи или `:hidden`")
    ensure_none!(env, labelled -- fields, "подписи полей вне struct'а")

    maps = for {name, {:type, :map}} <- specs(module), do: name
    ensure_none!(env, maps, "свободная map подписью не выходит — `:hidden`")
  end

  # ---

  defp ensure_none!(_env, [], _message), do: :ok
  defp ensure_none!(env, fields, message), do: fail!(env, "#{message}: #{inspect(fields)}")

  defp fail!(env, message) do
    raise CompileError, description: "#{where(env.module)}: #{message}", file: env.file, line: env.line
  end

  # ===== интроспекция =====

  @doc "Спека видимых полей struct'а — из спеки нагрузки, в порядке её объявления, без `:hidden`."
  @spec specs(module()) :: [{atom(), Plugin.Fields.spec()}]

  def specs(module) when is_atom(module) do
    labels = module.__label_fields__()

    for {name, spec, _optional?, _wire, _default} <- module.__es_payload_fields__(),
        Keyword.fetch!(labels, name) != :hidden,
        do: {name, spec}
  end

  # ===== общее =====

  defp where(module), do: "#{@label} #{inspect(module)}"
end
