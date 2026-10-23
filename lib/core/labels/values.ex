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

  # Значения Enum известны уже при раскрытии `use`: `use Core.Enum` выше отдаёт их `Core.Enum.declared_values/1`.
  @doc false
  @spec labels!(module(), term()) :: [{atom(), String.t()}]

  def labels!(module, labels) when is_atom(module),
    do: labels!(Core.Enum.declared_values(module), labels, "#{@label} #{inspect(module)}")

  @doc false
  @spec labels!([atom()] | nil, term(), String.t()) :: [{atom(), String.t()}]

  def labels!(values, labels, where) when is_binary(where) do
    values = values!(values, where)
    labels_where = "#{where}: labels"

    labels =
      for {value, text} <- Check.keyword!(labels, labels_where),
          do: {value, Check.text!(text, "#{labels_where}, значение #{value}")}

    labelled = Keyword.keys(labels)

    ensure_none!(values -- labelled, "значения без подписи", where)
    ensure_none!(labelled -- values, "подписи значений вне Enum", where)

    for value <- values, do: {value, Keyword.fetch!(labels, value)}
  end

  # ---

  defp values!([_ | _] = values, _where), do: values

  defp values!(_none, where) do
    raise CompileError, description: "#{where}: не Enum: `use Core.Labels.Values` подключается после `use Core.Enum`"
  end

  defp ensure_none!([], _message, _where), do: :ok

  defp ensure_none!(values, message, where),
    do: raise(CompileError, description: "#{where}: #{message}: #{inspect(values)}")
end
