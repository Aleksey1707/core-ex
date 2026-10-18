# `:sentry` объявлен в библиотеке `optional: true`: без SDK модуля нет (ADR-0071).
if Code.ensure_loaded?(Sentry) do
  defmodule Core.Web.CriticalError do
    @moduledoc """
    Отчёт о критической ошибке API в службу учёта ошибок (Sentry): запись и идентификатор ошибки
    для обёртки 500 (`Core.Web.ErrorMapper`, опция `error_id:`). Решение — ADR-0071.

    Зовут две точки ответа 500 потребителя: `FallbackController` на уровне `:error` из
    `Core.Web.ErrorMapper.map/2` и `ErrorJSON` на статусе 500. Доменный отказ, 401, 422 и прочие 5xx
    критической ошибкой не являются и в службу не уходят.

    Форма события по виду причины:

    | Причина | Событие | Доп. данные |
    |---|---|---|
    | исключение | исключение со stacktrace | — |
    | `%Error{}` | сообщение «Прикладная ошибка API: <текст>», fingerprint `"<ns>/<code>"` | `error` — `inspect/1` |
    | прочий term | сообщение «Необработанная ошибка API» | `reason` — `inspect/1` |

    Stacktrace, если он передан, есть у события любого вида.

    Значение Prim с `sensitive: true` или `personal: true` скрыто в доп. данных так же, как в логах:
    его `Inspect` значения не печатает.

    Модуль есть, только если `:sentry` был у приложения при сборке `core`; конфигурацию SDK задаёт
    потребитель.
    """

    alias Core.Error

    @doc """
    Записать критическую ошибку в службу и вернуть идентификатор ошибки — `event_id` события этого
    вызова (32 hex), либо `nil`, если записи нет: пустой DSN, событие отброшено SDK (`before_send`,
    `sample_rate`, дедупликация). `stacktrace` — `nil`, если его нет.

    Событие уходит асинхронно (`result: :none`): запрос службу не ждёт. Поэтому идентификатор берётся
    из события, собранного до отправки, а не из ответа службы и не из
    `Sentry.get_last_event_id_and_source/0` — тот в keep-alive процессе вернул бы id прошлого запроса.
    Событие отправляется `Sentry.send_event/2`, мимо `:filter` SDK: критическую ошибку зовут явно.
    Отказ уже после постановки в очередь отправки (лимит частоты службы, сетевой сбой) идентификатор
    не отменяет: вызов о нём не узнаёт.
    """
    @spec report(term(), Exception.stacktrace() | nil) :: String.t() | nil

    def report(reason, stacktrace) do
      event = event(reason, stacktrace)

      case Sentry.send_event(event, result: :none) do
        {:ok, _} -> event.event_id
        _not_recorded -> nil
      end
    end

    # ---

    defp event(%Error{ns: ns, code: code} = error, stacktrace) do
      Sentry.Event.create_event(
        [
          message: "Прикладная ошибка API: #{error}",
          fingerprint: ["#{ns}/#{code}"],
          extra: %{error: inspect(error)}
        ] ++ stacktrace_opts(stacktrace)
      )
    end

    defp event(exception, stacktrace) when is_exception(exception),
      do: Sentry.Event.transform_exception(exception, stacktrace_opts(stacktrace))

    defp event(reason, stacktrace) do
      Sentry.Event.create_event(
        [message: "Необработанная ошибка API", extra: %{reason: inspect(reason)}] ++ stacktrace_opts(stacktrace)
      )
    end

    defp stacktrace_opts(nil), do: []
    defp stacktrace_opts(stacktrace), do: [stacktrace: stacktrace]
  end
end
