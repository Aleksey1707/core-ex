defmodule Core.Web.HealthPlug do
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

  Неверные опции — `ArgumentError` на `init/1`: в эндпоинте Phoenix — при сборке. Репозиторий —
  модуль с `use Ecto.Repo`, пути — разные и от корня.
  """

  @behaviour Plug

  import Plug.Conn

  alias Core.Helper.StartOpts
  alias Plug.Conn

  require Logger

  @label "Web.HealthPlug"
  @keys ~w(repos health_path ready_path timeout)a
  @grace 100

  # ===== опции =====

  @doc false
  @spec init(keyword()) :: Plug.opts()

  @impl true
  def init(opts) when is_list(opts) do
    StartOpts.keys!(@label, opts, @keys)

    health = path!(opts, :health_path, "/health")
    ready = path!(opts, :ready_path, "/ready")

    if health == ready,
      do: StartOpts.raise_invalid!(@label, :ready_path, "путь, отличный от health_path:", ready)

    %{
      repos: repos!(opts),
      health: health,
      ready: ready,
      timeout: StartOpts.pos_integer!(@label, opts, :timeout, 1000)
    }
  end

  # ---

  defp repos!(opts) do
    repos = StartOpts.list!(@label, opts, :repos)

    if repos != [] and Enum.all?(repos, &repo?/1),
      do: repos,
      else: StartOpts.raise_invalid!(@label, :repos, "непустой список модулей с `use Ecto.Repo`", repos)
  end

  defp repo?(repo) do
    is_atom(repo) and match?({:module, _}, Code.ensure_compiled(repo)) and
      function_exported?(repo, :__adapter__, 0)
  end

  defp path!(opts, key, default) do
    case StartOpts.binary!(@label, opts, key, default) do
      "/" <> _ = path -> String.split(path, "/", trim: true)
      path -> StartOpts.raise_invalid!(@label, key, "путь от корня", path)
    end
  end

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
