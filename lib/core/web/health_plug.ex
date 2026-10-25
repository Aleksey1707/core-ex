defmodule Core.Web.HealthPlug do
  @init_opts_schema [
    repos: [
      type: {:custom, Core.Web.HealthPlug, :repos, []},
      type_doc: "список `t:module/0`",
      required: true,
      doc: "Непустой список модулей с `use Ecto.Repo`, которые проверяет readiness."
    ],
    health_path: [
      type: {:custom, Core.Web.HealthPlug, :path, []},
      type_doc: "`t:String.t/0`",
      default: "/health",
      doc: "Путь liveness от корня."
    ],
    ready_path: [
      type: {:custom, Core.Web.HealthPlug, :path, []},
      type_doc: "`t:String.t/0`",
      default: "/ready",
      doc: "Путь readiness от корня, отличный от `health_path:`."
    ],
    timeout: [type: :pos_integer, default: 1000, doc: "Таймаут запроса `SELECT 1` к репозиторию, мс."]
  ]

  @moduledoc """
  Плаг проверок живости и готовности: liveness на `health_path:`, readiness на `ready_path:`.

  - `health_path:` (`/health`) — `200` `ok` без проверок: liveness не должен перезапускать
    приложение из-за недоступной базы.
  - `ready_path:` (`/ready`) — `SELECT 1` по каждому репозиторию из `repos:` параллельно, запрос с
    таймаутом `timeout:` (1000 мс): `200` `ok`, если ответили все, иначе `503` `unavailable` и
    `warning` в лог на каждый неготовый репозиторий. По readiness compose и балансировщик не шлют
    трафик приложению без базы.

  Таймаут запроса отдаёт причину драйвера и соединение пулу. Проверку, которая не уложилась в
  `timeout:` с запасом (ожидание соединения в очереди пула), плаг снимает сам: ответ не виснет
  вместе с пулом.

  После ответа `conn` останавливается (`halt`); на прочих путях плаг пропускает `conn` дальше без
  изменений. Метод запроса не проверяется.

  ## Опции

  Неверные опции — `ArgumentError` на `init/1`: в эндпоинте Phoenix — при сборке.

  #{Core.Options.docs(@init_opts_schema)}
  """

  @behaviour Plug

  use Core.Options

  import Plug.Conn

  alias Core.Result
  alias Plug.Conn

  require Logger

  @grace 100

  # ===== опции =====

  @opts_schema @init_opts_schema
  @doc false
  @spec init(keyword()) :: Plug.opts()

  @impl true
  def init(opts) when is_list(opts) do
    health = segments(Keyword.fetch!(opts, :health_path))
    ready = segments(Keyword.fetch!(opts, :ready_path))

    if health == ready do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.init/1: опция :ready_path — ожидается путь, отличный от health_path:, " <>
              "получено #{inspect(Keyword.fetch!(opts, :ready_path))}"
    end

    %{repos: Keyword.fetch!(opts, :repos), health: health, ready: ready, timeout: Keyword.fetch!(opts, :timeout)}
  end

  @doc false
  @spec repos(term()) :: Result.t([module()], String.t())

  def repos(value) do
    if is_list(value) and value != [] and Enum.all?(value, &repo?/1),
      do: {:ok, value},
      else: {:error, "ожидается непустой список модулей с `use Ecto.Repo`, получено #{inspect(value)}"}
  end

  @doc false
  @spec path(term()) :: Result.t(String.t(), String.t())

  def path("/" <> _ = path), do: {:ok, path}
  def path(other), do: {:error, "ожидается путь от корня, получено #{inspect(other)}"}

  # ---

  defp repo?(repo) do
    is_atom(repo) and Core.Helper.Module.exports?(repo, :__adapter__, 0)
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  # ===== ответ =====

  @doc false
  @spec call(Conn.t(), Plug.opts()) :: Conn.t()

  @impl true
  def call(%Conn{path_info: path} = conn, %{health: path}), do: respond(conn, 200, "ok")
  def call(%Conn{path_info: path} = conn, %{ready: path} = opts), do: ready(conn, opts)
  def call(%Conn{} = conn, _opts), do: conn

  # ---

  defp ready(conn, %{repos: repos, timeout: timeout}) do
    case Enum.reject(check(repos, timeout), &match?({_repo, :ok}, &1)) do
      [] ->
        respond(conn, 200, "ok")

      failed ->
        Enum.each(failed, fn {repo, {:error, reason}} ->
          Logger.warning("health: репозиторий не готов: repo=#{inspect(repo)} reason=#{format(reason)}")
        end)

        respond(conn, 503, "unavailable")
    end
  end

  defp check(repos, timeout) do
    repos
    |> Task.async_stream(&ping(&1, timeout),
      timeout: timeout + @grace,
      on_timeout: :kill_task,
      max_concurrency: length(repos)
    )
    |> Enum.zip_with(repos, fn
      {:ok, result}, repo -> {repo, result}
      {:exit, reason}, repo -> {repo, {:error, reason}}
    end)
  end

  defp ping(repo, timeout) do
    select_one(repo, timeout)
  rescue
    error -> {:error, error}
  catch
    _kind, reason -> {:error, reason}
  end

  defp select_one(repo, timeout) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", [], timeout: timeout) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp format(reason) when is_exception(reason), do: Exception.message(reason)
  defp format(reason), do: inspect(reason)

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end
end
