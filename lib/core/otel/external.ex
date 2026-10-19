defmodule Core.Otel.External do
  @moduledoc """
  Span'ы внешнего вызова: словарь атрибутов `core.external.*` и операции, которые их ставят.

  | Функция | Span | Родитель |
  |---|---|---|
  | `call/3` | `<system> <operation>`, `:client` | span вызывающего |

  Атрибуты: `core.external.system`, `core.external.operation`, `peer.service` (= system: внешняя
  система видна в графе сервисов трейсов) — на старте; `core.external.outcome` — по исходу.

  | Исход | Статус span'а | `error.type` |
  |---|---|---|
  | `ok` | не ставится | — |
  | `rejected` | не ставится: отказ системы по существу — не сбой | — |
  | `timeout`, `down` | `:error` | имя исхода |
  | `exception` | `:error` | модуль исключения (`Core.Otel.record_exception/3`) |

  Исход определяет вызывающий (`Core.External.call/4`): смысл ответов конкретной системы словарю не
  известен.
  """

  alias Core.Otel

  @attr_system "core.external.system"
  @attr_operation "core.external.operation"
  @attr_outcome "core.external.outcome"
  @attr_peer_service "peer.service"

  @doc "Выполнить `fun` — вызов внешней системы — в span'е `<system> <operation>` внутри трейса вызывающего."
  @spec call(atom(), atom(), (-> result)) :: result when result: var

  def call(system, operation, fun) when is_atom(system) and is_atom(operation) and is_function(fun, 0) do
    system = Atom.to_string(system)
    operation = Atom.to_string(operation)

    attributes = %{
      @attr_system => system,
      @attr_operation => operation,
      @attr_peer_service => system
    }

    Otel.span("#{system} #{operation}", [kind: :client, attributes: attributes], fun)
  end

  @doc "Отметить исход вызова; `timeout` и `down` — статус `:error`."
  @spec outcome(Core.External.outcome()) :: :ok

  def outcome(outcome) when outcome in ~w(ok rejected)a, do: put_outcome(outcome)

  def outcome(outcome) when outcome in ~w(timeout down)a do
    :ok = put_outcome(outcome)
    Otel.record_failure(Atom.to_string(outcome))
  end

  @doc "Отметить исключение в вызове: исход `exception` и `Core.Otel.record_exception/3`."
  @spec raised(:error | :exit | :throw, term(), Exception.stacktrace()) :: :ok

  def raised(kind, reason, stacktrace) do
    :ok = put_outcome(:exception)
    Otel.record_exception(kind, reason, stacktrace)
  end

  # ---

  defp put_outcome(outcome), do: Otel.set_attributes(%{@attr_outcome => Atom.to_string(outcome)})
end
