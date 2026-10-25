defmodule Core.Web.ErrorMapper do
  @moduledoc """
  Таблица «ошибка → HTTP-ответ» для fallback-контроллера и `ErrorJSON` потребителя.

  Чистая функция: статус, обёртка ответа (`Core.Web.Response.error/1,2,3`) и уровень
  логирования (`nil` — не логировать). Сам `Logger` вызывает потребитель — так `map/2` остаётся
  запросом (CQS) и проверяется тестом построчно.

  `code` обёртки — `"<ns>/<code>"` доменной ошибки (`Core.Web.Response.error/1`): один `code`
  у разных `ns` — разные ошибки (ADR-0067). Константы — без `ns`: прикладная ошибка и ошибка
  программиста уходят `"internal_error"`, отказ авторизации — `"not_authorized"` (`unauthorized/1`
  для плага аутентификации), ошибка до контроллера — имя статуса (`by_status/2`), ошибка разбора
  запроса по OpenAPI — `"invalid_params"` (`cast_errors/2`). Состав множества ошибок (`Error.many`) уходит
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
  alias OpenApiSpex.Cast
  alias Plug.Conn.Status

  use Core.Options

  @auth_codes ~w(unauthorized auth_failed invalid_token session_not_found)a
  @unauthorized "Не авторизован"
  @critical "Произошла непредвиденная ошибка"

  @auth_opts [
    auth_codes: [
      type: {:list, :atom},
      default: @auth_codes,
      doc: "Коды `%Error{}`, которые уходят 401 независимо от `kind`."
    ]
  ]
  @unauthorized_opts [
    unauthorized_message: [type: :string, default: @unauthorized, doc: "Текст `message` ответа 401."]
  ]
  @critical_opts [
    critical_message: [type: :string, default: @critical, doc: "Шаблон `message` ответа 500, без точки в конце."],
    error_id: [
      type: {:or, [:string, nil]},
      type_doc: "`t:String.t/0` | `nil`",
      default: nil,
      doc: "Идентификатор ошибки из службы учёта ошибок для ответа 500 (`critical/1`); `nil` — без него."
    ]
  ]

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
  | `%Error{kind: :app}` | 500 | `"internal_error"` | шаблон, как у `critical/1` | `:error` |
  | прочее | 500 | `"internal_error"` | шаблон, как у `critical/1` | `:error` |

  Статус по `code:` разбирается только у `kind: :domain`: прикладную ошибку клиенту
  показывать нельзя, и она обязана попасть в лог (`12-errors.md`), поэтому `kind: :app`
  с любым кодом уходит в 500.

  Доменный `:not_found` своей строки не имеет и уходит 400 по строке `kind: :domain`, а не 404.
  `:not_found` домен отдаёт и на ресурс из URI, и на запись, на которую ссылается тело команды,
  а по `%Error{}` маппер их не различит: 404 на существующий ресурс клиент прочтёт как «ресурса
  нет». Отказу домена на команде с `If-Match` 404 не нужен — по RFC 9110 §13.2.1 ответу
  достаточно не быть ни 2xx, ни 412. Приложение, чей домен разводит коды «ресурс не найден» и
  «ссылка не найдена», может отдать 404 своей клозой `map/1` перед делегированием.

  Последняя clause принимает произвольный term намеренно: в `action_fallback` приходит
  `{:error, reason}` любой формы, и необработанный reason обязан стать 500, а не крашем.
  """
  @opts_schema @auth_opts ++ @unauthorized_opts ++ @critical_opts
  @spec map(term(), keyword()) :: result()

  def map(error, opts \\ [])

  def map(%Error{kind: :domain, code: :version_mismatch} = error, _opts), do: {412, Response.error(error), nil}
  def map(%Error{kind: :domain, code: :access_denied} = error, _opts), do: {403, Response.error(error), nil}

  def map(%Error{code: code} = error, opts) do
    if code in Keyword.fetch!(opts, :auth_codes),
      do: {401, unauthorized_error(opts), :debug},
      else: by_kind(error, opts)
  end

  def map(_reason, opts), do: {500, critical_error(opts), :error}

  # ---

  defp by_kind(%Error{kind: :domain} = error, _opts), do: {400, Response.error(error), nil}
  defp by_kind(%Error{kind: :app}, opts), do: {500, critical_error(opts), :error}

  # ===== unauthorized =====

  @doc """
  Обёртка ответа 401 для плага аутентификации: те же `"not_authorized"` и текст, что у строки 401
  `map/2` и у `by_status(401)`, — отказ уходит клиенту одной константой, где бы он ни случился.
  """
  @opts_schema @unauthorized_opts
  @spec unauthorized(keyword()) :: Response.error()

  def unauthorized(opts \\ []), do: unauthorized_error(opts)

  # ===== critical =====

  @doc """
  Обёртка ответа 500 на критическую ошибку: её собирают строки 500 `map/2` и `by_status(500)`.

  `code` — `"internal_error"`, `message` — шаблон. Идентификатор ошибки уходит клиенту дважды:
  полем `data.errorId` и вторым предложением `message` («<шаблон>. Идентификатор ошибки: <id>»).
  Без идентификатора `data` пуст. Решение — ADR-0071.
  """
  @opts_schema @critical_opts
  @spec critical(keyword()) :: Response.error()

  def critical(opts \\ []), do: critical_error(opts)

  # ===== by_status =====

  @doc """
  Обёртка ответа на ошибку, не дошедшую до контроллера, — для `ErrorJSON` потребителя
  (`render_errors:` у `Endpoint`): `def render(_template, %{status: status}), do: by_status(status)`.

  | Статус | `code` | `message` |
  |---|---|---|
  | 401 | `"not_authorized"` | константа, как у `unauthorized/1` |
  | 4xx из таблицы Plug | имя статуса (`Plug.Conn.Status.reason_atom/1`) | фраза статуса |
  | 4xx вне таблицы Plug | `"bad_request"` | фраза 400 |
  | 500 | `"internal_error"` | шаблон, как у `critical/1` |
  | 5xx кроме 500 | `"internal_error"` | шаблон без идентификатора ошибки |

  Статус вне таблицы Plug отдаёт чужой плаг (`Plug.Exception.status/1`), и рендер ответа на ошибку
  не имеет права упасть вместо обёртки.
  """
  @opts_schema @unauthorized_opts ++ @critical_opts
  @spec by_status(400..599, keyword()) :: Response.error()

  def by_status(status, opts \\ [])

  def by_status(401, opts), do: unauthorized_error(opts)

  def by_status(status, _opts) when status in 400..499 do
    Response.error(Status.reason_atom(status), Status.reason_phrase(status))
  rescue
    ArgumentError -> Response.error(:bad_request, Status.reason_phrase(400))
  end

  def by_status(500, opts), do: critical_error(opts)
  def by_status(status, opts) when status in 501..599, do: critical_error(Keyword.put(opts, :error_id, nil))

  # ===== cast_errors =====

  if Code.ensure_loaded?(Cast.Error) do
    @invalid_params "Некорректные параметры запроса"
    @composite ~w(any_of one_of)a
    @no_schema_match "Value matches none of the allowed schemas"
    @many_schemas_match "Value matches more than one of the allowed schemas"

    @doc """
    Ответ на ошибку разбора запроса по OpenAPI — для плага `render_error:` у
    `OpenApiSpex.Plug.CastAndValidate` потребителя: `{422, обёртка, nil}`, как строка `map/2`.

    `code` — `"invalid_params"`, `message` — константа, нарушения — `data.errors`: у элемента
    `code` — `reason` нарушения (`"missing_field"`, `"invalid_type"`, …), `message` — текст
    OpenApiSpex с путём поля. Неудавшаяся составная схема (`anyOf` / `oneOf`) — один элемент
    `"any_of"` / `"one_of"` на её путь, без названий схем и без нарушений её ветвей: какая ветвь
    своя, без discriminator неизвестно. Решение — ADR-0068.

    Функция есть, только если `open_api_spex` был у приложения при сборке `core` (ADR-0064).
    """
    @opts_schema [
      invalid_params_message: [type: :string, default: @invalid_params, doc: "Текст `message` ответа 422."]
    ]
    @spec cast_errors([Cast.Error.t(), ...], keyword()) :: result()

    def cast_errors([_ | _] = errors, opts \\ []) do
      message = Keyword.fetch!(opts, :invalid_params_message)

      violations = Enum.map(drop_branches(errors), &violation/1)

      {422, Response.error(:invalid_params, message, %{errors: violations}), nil}
    end

    # ---

    defp drop_branches(errors) do
      composite_paths =
        for %Cast.Error{reason: reason, path: path} when reason in @composite <- errors, uniq: true, do: path

      {kept, _owners} = Enum.flat_map_reduce(errors, [], &keep(&1, &2, composite_paths))
      kept
    end

    defp keep(%Cast.Error{reason: reason, path: path} = error, owners, composite_paths) when reason in @composite do
      if path in owners or Enum.any?(composite_paths, &under?(path, &1)),
        do: {[], owners},
        else: {[error], [path | owners]}
    end

    defp keep(%Cast.Error{path: path} = error, owners, composite_paths) do
      if Enum.any?(composite_paths, &List.starts_with?(path, &1)), do: {[], owners}, else: {[error], owners}
    end

    defp under?(path, prefix), do: path != prefix and List.starts_with?(path, prefix)

    defp violation(%Cast.Error{reason: :one_of, meta: %{valid_schemas: [_ | _]}} = error),
      do: %{code: "one_of", message: with_path(error, @many_schemas_match)}

    defp violation(%Cast.Error{reason: reason} = error) when reason in @composite,
      do: %{code: Atom.to_string(reason), message: with_path(error, @no_schema_match)}

    defp violation(%Cast.Error{reason: reason} = error),
      do: %{code: Atom.to_string(reason), message: Cast.Error.message_with_path(error)}

    defp with_path(%Cast.Error{path: []}, message), do: "#: " <> message
    defp with_path(error, message), do: "#" <> Cast.Error.path_to_string(error) <> ": " <> message
  end

  # ===== общее =====

  defp unauthorized_error(opts), do: Response.error(:not_authorized, Keyword.fetch!(opts, :unauthorized_message))

  defp critical_error(opts) do
    message = Keyword.fetch!(opts, :critical_message)

    case Keyword.fetch!(opts, :error_id) do
      nil ->
        Response.error(:internal_error, message)

      error_id when is_binary(error_id) ->
        Response.error(:internal_error, message <> ". Идентификатор ошибки: " <> error_id, %{errorId: error_id})
    end
  end
end
