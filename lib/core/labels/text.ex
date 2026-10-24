defmodule Core.Labels.Text do
  @moduledoc """
  Prim текстом — значение, которое человеку показывают не им самим, а текстом функции (ADR-0063).

  Подключается в Prim после `use Core.Prim.*`, когда значение — машинный код, а человек читает его по
  имени:

      defmodule MyApp.Domain.Sales.Account.Currency do
        use Core.Prim.String,
          name: "Валюта",
          min_len: 3,
          max_len: 3

        use Core.Labels.Text, with: &MyApp.Domain.Sales.Account.Currency.title/1
      end

  Функция получает Prim и отдаёт строку, `nil` ей не передаётся. Поле этого Prim выходит в сведения
  (`Core.Labels.Details`) видом `:text` с результатом функции; Prim-композит над таким Prim — тоже:
  функция получает базовый Prim.

  Сборку ломают: `with:` не захватом функции арности 1 (`&Mod.fun/1` — анонимная функция модуля,
  который ещё собирается, в атрибут не сохраняется), `use` не после `use Core.Prim.*` и
  `use Core.Labels.ID` в том же Prim — у значения один способ выйти в сведения.

  Макрос занимает в Prim имя `__label_text__/0`.
  """

  alias Core.Labels.Check

  @label "Labels.Text"
  @required_keys ~w(with)a
  @optional_keys []

  # ===== объявление =====

  @doc "Объявить функцию текста Prim (`with:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Core.Helper.Opts.validate!(
        opts,
        Core.Labels.Text.required_keys(),
        Core.Labels.Text.optional_keys(),
        "Labels.Text"
      )

      Core.Labels.Check.prim!(
        Core.Prim.declared?(__MODULE__),
        Core.Labels.ID.declared?(__MODULE__) or Core.Labels.Text.declared?(__MODULE__),
        "Core.Labels.Text",
        "Labels.Text #{inspect(__MODULE__)}"
      )

      @label_text Core.Labels.Text.declare!(__MODULE__, Keyword.fetch!(opts, :with))

      @doc false
      @spec __label_text__() :: (struct() -> String.t())

      def __label_text__, do: @label_text
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec declare!(module(), term()) :: (struct() -> String.t())

  def declare!(module, fun) when is_atom(module), do: Check.capture!(fun, 1, "#{where(module)}: with")

  # ---

  defp where(module), do: "#{@label} #{inspect(module)}"

  # ===== интроспекция =====

  @doc false
  @spec declared?(module()) :: boolean()

  def declared?(module) when is_atom(module), do: Module.defines?(module, {:__label_text__, 0})

  @doc "Функция текста Prim или `nil`, если Prim её не объявляет."
  @spec find(module()) :: (struct() -> String.t()) | nil

  def find(module) when is_atom(module) do
    if Core.Helper.Module.exports?(module, :__label_text__, 0), do: module.__label_text__()
  end
end
