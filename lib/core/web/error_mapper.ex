defmodule Core.Web.ErrorMapper do
  @moduledoc """
  Таблица «ошибка → HTTP-ответ» для fallback-контроллера потребителя.

  Чистая функция: статус, обёртка ответа (`Core.Web.Response.error/2,3`) и уровень
  логирования (`nil` — не логировать). Сам `Logger` вызывает потребитель — так `map/2` остаётся
  запросом (CQS) и проверяется тестом построчно.

  `code` обёртки — код доменной ошибки; прикладная и программиста уходят константой
  `"internal_error"`, отказ авторизации — `"not_authorized"`. Состав множества ошибок
  (`Error.many`) уходит в `data.errors` только на доменных строках таблицы: на 401 и 500
  тексты элементов наружу не попадают.

  На 401 наружу уходят **константы** независимо от причины: разные коды и тексты на отказ
  авторизации позволяют перебирать существующие учётки, сессии и токены. Причина остаётся
  в логе (`Error.format_chain/1`).

  Своя строка таблицы — свои клозы перед делегированием; `map/2` не макрос и не behaviour:

      defmodule MyAppWeb.ErrorMapper do
        @spec map(term()) :: Core.Web.ErrorMapper.result()

        def map(%Error{ns: :billing, code: :quota_exceeded} = err),
          do: {429, Core.Web.Response.error(err.code, err.message), :debug}

        def map(other), do: Core.Web.ErrorMapper.map(other, auth_codes: ~w(no_session)a)
      end
  """

  alias Core.Error
  alias Core.Web.Response

  @auth_codes ~w(unauthorized auth_failed invalid_token session_not_found)a
  @unauthorized "Не авторизован"
  @critical "Произошла непредвиденная ошибка"

  @typedoc "Статус, обёртка ответа и уровень логирования (`nil` — не логировать)."
  @type result :: {100..599, Response.error(), Logger.level() | nil}

  @doc """
  Разложить ошибку на HTTP-ответ.

  | Ошибка | Статус | `code` | `message` | Лог |
  |---|---|---|---|---|
  | `%Error{kind: :domain, code: :version_mismatch}` | 412 | `"version_mismatch"` | `message` | — |
  | `%Error{kind: :domain, code: :access_denied}` | 403 | `"access_denied"` | `message` | — |
  | `%Error{code: c}`, `c` в `auth_codes:` | 401 | `"not_authorized"` | константа | `:debug` |
  | `%Error{kind: :domain}` | 400 | `code` ошибки | `message` | — |
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

  def map(%Error{kind: :domain, code: :version_mismatch} = error, _opts), do: {412, domain_body(error), nil}

  def map(%Error{kind: :domain, code: :access_denied} = error, _opts), do: {403, domain_body(error), nil}

  def map(%Error{code: code} = error, opts) do
    if code in Keyword.get(opts, :auth_codes, @auth_codes),
      do: {401, Response.error(:not_authorized, unauthorized_message(opts)), :debug},
      else: by_kind(error, opts)
  end

  def map(_reason, opts), do: critical(opts)

  # ---

  defp by_kind(%Error{kind: :domain} = error, _opts), do: {400, domain_body(error), nil}

  defp by_kind(%Error{kind: :app}, opts), do: critical(opts)

  defp domain_body(%Error{errors: []} = error), do: Response.error(error.code, to_string(error))

  defp domain_body(%Error{errors: [_ | _] = errors} = error),
    do: Response.error(error.code, to_string(error), %{errors: Enum.map(errors, &element/1)})

  defp element(%Error{} = error), do: %{code: Atom.to_string(error.code), message: to_string(error)}

  defp critical(opts), do: {500, Response.error(:internal_error, critical_message(opts)), :error}

  defp unauthorized_message(opts), do: Keyword.get(opts, :unauthorized_message, @unauthorized)

  defp critical_message(opts), do: Keyword.get(opts, :critical_message, @critical)
end
