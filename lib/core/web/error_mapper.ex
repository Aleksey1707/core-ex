defmodule Core.Web.ErrorMapper do
  @moduledoc """
  Таблица «ошибка → HTTP-ответ» для fallback-контроллера и `ErrorJSON` потребителя.

  Чистая функция: статус, обёртка ответа (`Core.Web.Response.error/1,2,3`) и уровень
  логирования (`nil` — не логировать). Сам `Logger` вызывает потребитель — так `map/2` остаётся
  запросом (CQS) и проверяется тестом построчно.

  `code` обёртки — `"<ns>/<code>"` доменной ошибки (`Core.Web.Response.error/1`): один `code`
  у разных `ns` — разные ошибки (ADR-0067). Константы — без `ns`: прикладная ошибка и ошибка
  программиста уходят `"internal_error"`, отказ авторизации — `"not_authorized"`, ошибка до
  контроллера — имя статуса (`by_status/2`). Состав множества ошибок (`Error.many`) уходит
  в `data.errors` только на доменных строках таблицы: на 401 и 500 тексты элементов наружу
  не попадают.

  На 401 наружу уходят **константы** независимо от причины: разные коды и тексты на отказ
  авторизации позволяют перебирать существующие учётки, сессии и токены. Причина остаётся
  в логе (`Error.format_chain/1`).

  Своя строка таблицы — свои клозы перед делегированием; `map/2` не макрос и не behaviour:

      defmodule MyAppWeb.ErrorMapper do
        @spec map(term()) :: Core.Web.ErrorMapper.result()

        def map(%Error{ns: :billing, code: :quota_exceeded} = err),
          do: {429, Core.Web.Response.error(err), :debug}

        def map(other), do: Core.Web.ErrorMapper.map(other, auth_codes: ~w(no_session)a)
      end
  """

  alias Core.Error
  alias Core.Web.Response
  alias Plug.Conn.Status

  @auth_codes ~w(unauthorized auth_failed invalid_token session_not_found)a
  @unauthorized "Не авторизован"
  @critical "Произошла непредвиденная ошибка"

  @typedoc "Статус, обёртка ответа и уровень логирования (`nil` — не логировать)."
  @type result :: {100..599, Response.error(), Logger.level() | nil}

  # ===== map =====

  @doc """
  Разложить ошибку на HTTP-ответ.

  | Ошибка | Статус | `code` | `message` | Лог |
  |---|---|---|---|---|
  | `%Error{kind: :domain, code: :version_mismatch}` | 412 | `"<ns>/version_mismatch"` | `message` | — |
  | `%Error{kind: :domain, code: :access_denied}` | 403 | `"<ns>/access_denied"` | `message` | — |
  | `%Error{code: c}`, `c` в `auth_codes:` | 401 | `"not_authorized"` | константа | `:debug` |
  | `%Error{kind: :domain}` | 400 | `"<ns>/<code>"` ошибки | `message` | — |
  | `%Error{kind: :app}` | 500 | `"internal_error"` | шаблон | `:error` |
  | прочее | 500 | `"internal_error"` | шаблон | `:error` |

  Статус по `code:` разбирается только у `kind: :domain`: прикладную ошибку клиенту
  показывать нельзя, и она обязана попасть в лог (`12-errors.md`), поэтому `kind: :app`
  с любым кодом уходит в 500.

  Доменный `:not_found` своей строки не имеет и уходит 400 по строке `kind: :domain`, а не 404.
  `:not_found` домен отдаёт и на ресурс из URI, и на запись, на которую ссылается тело команды,
  а по `%Error{}` маппер их не различит: 404 на существующий ресурс клиент прочтёт как «ресурса
  нет». Отказу домена на команде с `If-Match` 404 не нужен — по RFC 9110 §13.2.1 ответу
  достаточно не быть ни 2xx, ни 412. Приложение, чей домен разводит коды «ресурс не найден» и
  «ссылка не найдена», может отдать 404 своей клозой `map/1` перед делегированием.

  Опции: `auth_codes:` (дефолт `#{inspect(@auth_codes)}`), `unauthorized_message:`,
  `critical_message:`.

  Последняя clause принимает произвольный term намеренно: в `action_fallback` приходит
  `{:error, reason}` любой формы, и необработанный reason обязан стать 500, а не крашем.
  """
  @spec map(term(), keyword()) :: result()

  def map(error, opts \\ [])

  def map(%Error{kind: :domain, code: :version_mismatch} = error, _opts), do: {412, Response.error(error), nil}

  def map(%Error{kind: :domain, code: :access_denied} = error, _opts), do: {403, Response.error(error), nil}

  def map(%Error{code: code} = error, opts) do
    if code in Keyword.get(opts, :auth_codes, @auth_codes),
      do: {401, Response.error(:not_authorized, unauthorized_message(opts)), :debug},
      else: by_kind(error, opts)
  end

  def map(_reason, opts), do: critical(opts)

  # ---

  defp by_kind(%Error{kind: :domain} = error, _opts), do: {400, Response.error(error), nil}

  defp by_kind(%Error{kind: :app}, opts), do: critical(opts)

  defp critical(opts), do: {500, Response.error(:internal_error, critical_message(opts)), :error}

  defp unauthorized_message(opts), do: Keyword.get(opts, :unauthorized_message, @unauthorized)

  # ===== by_status =====

  @doc """
  Обёртка ответа на ошибку, не дошедшую до контроллера, — для `ErrorJSON` потребителя
  (`render_errors:` у `Endpoint`): `def render(_template, %{status: status}), do: by_status(status)`.

  | Статус | `code` | `message` |
  |---|---|---|
  | 4xx из таблицы Plug | имя статуса (`Plug.Conn.Status.reason_atom/1`) | фраза статуса |
  | 4xx вне таблицы Plug | `"bad_request"` | фраза 400 |
  | 5xx | `"internal_error"` | шаблон, как у `map/2` |

  Статус вне таблицы Plug отдаёт чужой плаг (`Plug.Exception.status/1`), и рендер ответа на ошибку
  не имеет права упасть вместо обёртки. Опция: `critical_message:`.
  """
  @spec by_status(400..599, keyword()) :: Response.error()

  def by_status(status, opts \\ [])

  def by_status(status, _opts) when status in 400..499 do
    Response.error(Status.reason_atom(status), Status.reason_phrase(status))
  rescue
    ArgumentError -> Response.error(:bad_request, Status.reason_phrase(400))
  end

  def by_status(status, opts) when status in 500..599, do: Response.error(:internal_error, critical_message(opts))

  # ===== общее =====

  defp critical_message(opts), do: Keyword.get(opts, :critical_message, @critical)
end
