defmodule Core.Web.ErrorMapper do
  @moduledoc """
  Таблица «ошибка → HTTP-ответ» для fallback-контроллера потребителя.

  Чистая функция: статус, код конверта, текст для клиента и уровень логирования (`nil` —
  не логировать). Сам `Logger` вызывает потребитель — так `map/2` остаётся запросом (CQS)
  и проверяется тестом построчно.

  На 401 наружу уходит **константа** независимо от причины: разные тексты на отказ
  авторизации позволяют перебирать существующие учётки, сессии и токены. Причина остаётся
  в логе (`Error.format_chain/1`).

  Своя строка таблицы — свои клозы перед делегированием; `map/2` не макрос и не behaviour:

      defmodule MyAppWeb.ErrorMapper do
        @spec map(term()) :: Core.Web.ErrorMapper.result(MyAppWeb.Response.Code.t())

        def map(%Error{ns: :billing, code: :quota_exceeded} = err),
          do: {429, :error, err.message, :debug}

        def map(other), do: Core.Web.ErrorMapper.map(other, auth_codes: ~w(no_session)a)
      end

  Свои **коды конверта** — свой словарь и `use Core.Web.Response` (см. `Core.Web.Response`).
  """

  alias Core.Error
  alias Core.Web.Response

  @auth_codes ~w(unauthorized auth_failed invalid_token session_not_found)a
  @unauthorized "Не авторизован"
  @critical "Произошла непредвиденная ошибка"

  @typedoc """
  Статус, код конверта, текст клиенту и уровень логирования (`nil` — не логировать).

  Параметр — тип словаря кодов: у потребителя со своим `Core.Enum` это его `t()`.
  """
  @type result(code) :: {100..599, code, String.t(), Logger.level() | nil}

  @typedoc "`result/1` на базовом словаре `Core.Web.Response.Code`."
  @type result :: result(Response.Code.t())

  @doc """
  Разложить ошибку на HTTP-ответ.

  | Ошибка | Статус | Код | Текст | Лог |
  |---|---|---|---|---|
  | `%Error{kind: :domain, code: :version_mismatch}` | 412 | `:diff_version` | `message` | — |
  | `%Error{kind: :domain, code: :access_denied}` | 403 | `:error` | `message` | — |
  | `%Error{code: c}`, `c` в `auth_codes:` | 401 | `:auth_error` | константа | `:debug` |
  | `%Error{kind: :domain}` | 400 | `:domain_error` | `message` | — |
  | `%Error{kind: :app}` | 500 | `:critical` | шаблон | `:error` |
  | прочее | 500 | `:critical` | шаблон | `:error` |

  Статус по `code:` разбирается только у `kind: :domain`: прикладную ошибку клиенту
  показывать нельзя, и она обязана попасть в лог (`12-errors.md`), поэтому `kind: :app`
  с любым кодом уходит в 500.

  Опции: `auth_codes:` (дефолт `#{inspect(@auth_codes)}`), `unauthorized_message:`,
  `critical_message:`.

  Последняя clause принимает произвольный term намеренно: в `action_fallback` приходит
  `{:error, reason}` любой формы, и необработанный reason обязан стать 500, а не крашем.
  """
  @spec map(term(), keyword()) :: result()

  def map(error, opts \\ [])

  def map(%Error{kind: :domain, code: :version_mismatch} = error, _opts),
    do: {412, :diff_version, to_string(error), nil}

  def map(%Error{kind: :domain, code: :access_denied} = error, _opts),
    do: {403, :error, to_string(error), nil}

  def map(%Error{code: code} = error, opts) do
    if code in Keyword.get(opts, :auth_codes, @auth_codes),
      do: {401, :auth_error, unauthorized_message(opts), :debug},
      else: by_kind(error, opts)
  end

  def map(_reason, opts), do: critical(opts)

  # ---

  defp by_kind(%Error{kind: :domain} = error, _opts),
    do: {400, :domain_error, to_string(error), nil}

  defp by_kind(%Error{kind: :app}, opts), do: critical(opts)

  defp critical(opts), do: {500, :critical, critical_message(opts), :error}

  defp unauthorized_message(opts), do: Keyword.get(opts, :unauthorized_message, @unauthorized)

  defp critical_message(opts), do: Keyword.get(opts, :critical_message, @critical)
end
