defmodule Core.External do
  @moduledoc """
  Внешний вызов: обращение приложения к системе вне его границ (платёжный шлюз, касса, служба
  доставки, SMS) с закрытым множеством исходов.

  `call/4` оборачивает вызов адаптера и возвращает результат `fun` без изменений. У вызова:

  - span `<system> <operation>` вида `:client` в трейсе вызывающего — словарь `Core.Otel.External`;
  - `:telemetry.span/3` с суффиксом `[:external, :call]` и метаданными `system`, `operation`,
    `outcome` в `:stop` — метрики `Core.External.PromEx`.

  | Исход | Смысл |
  |---|---|
  | `:ok` | система выполнила вызов |
  | `:timeout` | система не ответила за отведённое время |
  | `:down` | система недоступна: соединение не установлено, ответ 5xx и т. п. |
  | `:rejected` | система ответила отказом по существу: вызов дошёл, но не выполнен |
  | `:exception` | `fun` поднял исключение, `exit` или `throw`; ставит сама обёртка |

  Исход определяет вызывающий функцией `outcome:` по результату `fun`: смысл ответов конкретной
  системы библиотеке не известен. Исход вне множества — ошибка программиста (`ArgumentError`): как
  и падение самого классификатора, она уходит в telemetry событием `:exception` и в метрики исходов
  не попадает.
  Исключение в `fun` поднимается заново тем же видом и со своим стеком после закрытия span'а; в
  telemetry оно — `:stop` с исходом `:exception`, а не событие `:exception`, чтобы длительность и
  счётчик исходов жили в одной серии. Повторов и circuit breaker обёртка не делает.

  ```elixir
  Core.External.call(:payment_gateway, :charge, fn -> Gateway.charge(payment) end,
    outcome: &Gateway.outcome/1
  )
  ```
  """

  alias Core.Otel
  alias Core.Telemetry

  @outcomes ~w(ok timeout down rejected)a

  @typedoc "Исход вызова, который определяет классификатор вызывающего."
  @type outcome :: :ok | :timeout | :down | :rejected

  @doc """
  Выполнить вызов внешней системы `system` операцией `operation`; результат `fun` — без изменений.

  Опция `outcome:` (обязательная) — классификатор «результат `fun` → исход».
  """
  @spec call(atom(), atom(), (-> result), outcome: (result -> outcome())) :: result when result: var

  def call(system, operation, fun, opts)
      when is_atom(system) and is_atom(operation) and is_function(fun, 0) and is_list(opts) do
    classify = classifier!(opts)
    metadata = %{system: system, operation: operation}

    system
    |> Otel.External.call(operation, fn ->
      Telemetry.span([:external, :call], metadata, fn ->
        {completion, outcome} = complete(fun, classify)
        {completion, Map.put(metadata, :outcome, outcome)}
      end)
    end)
    |> finish()
  end

  # ---

  defp classifier!(opts) do
    case Keyword.fetch(opts, :outcome) do
      {:ok, classify} when is_function(classify, 1) ->
        classify

      _missing ->
        raise ArgumentError,
              "Core.External.call: обязательная опция outcome: — функция «результат → одно из " <>
                "#{inspect(@outcomes)}»"
    end
  end

  defp complete(fun, classify) do
    case invoke(fun) do
      {:returned, result} = completion ->
        outcome = outcome!(classify.(result))
        :ok = Otel.External.outcome(outcome)
        {completion, outcome}

      {:raised, kind, reason, stacktrace} = completion ->
        :ok = Otel.External.raised(kind, reason, stacktrace)
        {completion, :exception}
    end
  end

  defp invoke(fun) do
    {:returned, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp outcome!(outcome) when outcome in @outcomes, do: outcome

  defp outcome!(other) do
    raise ArgumentError,
          "Core.External.call: классификатор outcome: вернул #{inspect(other)}, ожидается одно из " <>
            "#{inspect(@outcomes)}"
  end

  defp finish({:returned, result}), do: result
  defp finish({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)
end
