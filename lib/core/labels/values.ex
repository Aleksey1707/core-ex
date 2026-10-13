defmodule Core.Labels.Values do
  @moduledoc """
  Подписи значений Enum — текст значения для человека (ADR-0063).

  Подключается в Enum после `use Core.Enum`:

      defmodule MyApp.Domain.Sales.Account.Status do
        use Core.Enum,
          name: "Статус счёта",
          values: ~w(active closed)a

        use Core.Labels.Values,
          labels: [
            active: "Активен",
            closed: "Закрыт"
          ]
      end

  Порождает `label/1` — подпись значения — и `labels/0` — пары «значение — подпись» в порядке
  `values/0`, а не `labels:`: из них строится форма выбора. `label/1` принимает только значения
  Enum: голова закрывает домен, иное — `FunctionClauseError`. Поле нагрузки вида `enum:` выходит в
  сведения (`Core.Labels.Details`) текстом — подписью значения.

  Сборку ломают: значение без подписи, подпись вне Enum, повтор значения, пустая или не строковая
  подпись, `labels:` не keyword-списком и `use` не после `use Core.Enum`.

  Макрос занимает в Enum имена `label/1` и `labels/0`.
  """

  alias Core.Labels.Check

  @label "Labels.Values"
  @required_keys ~w(labels)a
  @optional_keys []

  @doc "Объявить подпись каждого значения Enum (`labels:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Core.Helper.Opts.validate!(
        opts,
        Core.Labels.Values.required_keys(),
        Core.Labels.Values.optional_keys(),
        "Labels.Values"
      )

      @label_values Core.Labels.Values.labels!(__MODULE__, Keyword.fetch!(opts, :labels))

      @doc "Подпись значения enum."
      @spec label(t()) :: String.t()

      for {value, text} <- @label_values do
        def label(unquote(value)), do: unquote(text)
      end

      @doc "Пары «значение — подпись» в порядке `values/0`."
      @spec labels() :: [{t(), String.t()}]

      def labels, do: @label_values
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  # Значения Enum известны уже при раскрытии `use`: `use Core.Enum` выше положил их в атрибут.
  @doc false
  @spec labels!(module(), term()) :: [{atom(), String.t()}]

  def labels!(module, labels) when is_atom(module) do
    values = values!(module)
    where = "#{where(module)}: labels:"

    labels =
      for {value, text} <- Check.keyword!(labels, where), do: {value, Check.text!(text, "#{where} значение #{value}")}

    labelled = Keyword.keys(labels)

    ensure_none!(module, values -- labelled, "значения без подписи")
    ensure_none!(module, labelled -- values, "подписи значений вне Enum")

    for value <- values, do: {value, Keyword.fetch!(labels, value)}
  end

  # ---

  defp values!(module) do
    case Module.get_attribute(module, :enum_values) do
      [_ | _] = values ->
        values

      _none ->
        raise CompileError,
          description: "#{where(module)} — не Enum: `use Core.Labels.Values` подключается после `use Core.Enum`"
    end
  end

  defp ensure_none!(_module, [], _message), do: :ok

  defp ensure_none!(module, values, message),
    do: raise(CompileError, description: "#{where(module)}: #{message}: #{inspect(values)}")

  defp where(module), do: "#{@label} #{inspect(module)}"
end
