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

  `labels:` — литерал (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов функции —
  `CompileError` «ожидается литерал».

  Сборку ломают: значение без подписи, подпись вне Enum, повтор значения, пустая или не строковая
  подпись, `labels:` не keyword-списком и `use` не после `use Core.Enum`.

  Макрос занимает в Enum имена `label/1` и `labels/0`.
  """

  alias Core.Helper
  alias Core.Labels.Check

  @label "Labels.Values"
  @required_keys ~w(labels)a
  @optional_keys []
  @expression_keys []

  # ===== объявление =====

  @doc "Объявить подпись каждого значения Enum (`labels:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    labels = texts!(opts[:labels])

    [
      quote do
        @label_values Core.Labels.Values.labels!(
                        Core.Enum.declared_values(__MODULE__),
                        unquote(Macro.escape(labels))
                      )
      end,
      quote unquote: false do
        @doc "Подпись значения enum."
        @spec label(t()) :: String.t()

        for {value, text} <- @label_values do
          def label(unquote(value)), do: unquote(text)
        end

        @doc "Пары «значение — подпись» в порядке `values/0`."
        @spec labels() :: [{t(), String.t()}]

        def labels, do: @label_values
      end
    ]
  end

  # ---

  defp texts!(labels) do
    where = "#{@label}: labels"

    for {value, text} <- Check.keyword!(labels, where), do: {value, Check.text!(text, "#{where}: #{value}")}
  end

  # ===== сверка со значениями Enum =====

  # Значения Enum известны только телу: `use Core.Enum` выше пишет их атрибутом, `Core.Enum.declared_values/1`.
  @doc false
  @spec labels!([atom()] | nil, [{atom(), String.t()}]) :: [{atom(), String.t()}]

  def labels!(values, labels) do
    values = values!(values)
    labelled = Keyword.keys(labels)

    ensure_none!(values -- labelled, "значения без подписи")
    ensure_none!(labelled -- values, "подписи значений вне Enum")

    for value <- values, do: {value, Keyword.fetch!(labels, value)}
  end

  # ---

  defp values!([_ | _] = values), do: values

  defp values!(_none),
    do: Helper.Opts.reject!(@label, "не Enum: `use Core.Labels.Values` подключается после `use Core.Enum`")

  defp ensure_none!([], _message), do: :ok
  defp ensure_none!(values, message), do: Helper.Opts.reject!(@label, "#{message}: #{inspect(values)}")
end
