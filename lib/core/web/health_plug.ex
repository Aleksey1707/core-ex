defmodule Core.Web.HealthPlug do
  @moduledoc """
  Плаг проверок живости и готовности: liveness на `health_path:`, readiness на `ready_path:`.

  - `health_path:` (`/health`) — `200` `ok` без проверок: liveness не должен перезапускать
    приложение из-за недоступной базы.
  - `ready_path:` (`/ready`) — `SELECT 1` по каждому репозиторию приложения (`:ecto_repos` либо
    `repos:`) параллельно, запрос с таймаутом `timeout:` (1000 мс): `200` `ok`, если ответили все,
    иначе `503` `unavailable` и `warning` в лог на каждый неготовый репозиторий. По readiness
    compose и балансировщик не шлют трафик приложению без базы.

  Список репозиториев плаг берёт сам: эндпоинт не называет `DAO` приложения, а readiness не
  расходится с `:ecto_repos`. `:ecto_repos` читается на пробе, а не на `init/1`: эндпоинт Phoenix
  вызывает `init/1` при сборке, и конфигурация приложения оказалась бы зашита в его байткод.

  Таймаут запроса отдаёт причину драйвера и соединение пулу. Проверку, которая не уложилась в
  `timeout:` с запасом (ожидание соединения в очереди пула), плаг снимает сам: ответ не виснет
  вместе с пулом.

  После ответа `conn` останавливается (`halt`); на прочих путях плаг пропускает `conn` дальше без
  изменений. Метод запроса не проверяется.

  Неверные опции — `ArgumentError` на `init/1`: в эндпоинте Phoenix — при сборке.
  """

  @behaviour Plug

  use Core.Options

  import Plug.Conn

  alias Core.Config
  alias Core.Result
  alias Plug.Conn

  require Logger

  @grace 100

  # ===== опции =====

  @opts_schema [
    repos: [
      type: {:custom, Core.Web.HealthPlug, :repos, []},
      type_doc: "список `t:module/0`",
      doc:
        "Непустой список модулей с `use Ecto.Repo`, которые проверяет readiness. Без опции — " <>
          "`Core.Config.ecto_repos/0`, прочитанный на каждой пробе."
    ],
    health_path: [
      type: :string,
      default: "/health",
      doc: "Путь liveness от корня."
    ],
    ready_path: [
      type: :string,
      default: "/ready",
      doc: "Путь readiness от корня, отличный от `health_path:`."
    ],
    timeout: [type: :pos_integer, default: 1000, doc: "Таймаут запроса `SELECT 1` к репозиторию, мс."]
  ]
  @doc false
  @spec init(keyword()) :: Plug.opts()

  @impl true
  def init(opts) when is_list(opts) do
    health = segments(path!(opts, :health_path))
    ready = segments(path!(opts, :ready_path))

    if health == ready do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.init/1: опция :ready_path — ожидается путь, отличный от health_path:, " <>
              "получено #{inspect(Keyword.fetch!(opts, :ready_path))}"
    end

    %{repos: Keyword.get(opts, :repos), health: health, ready: ready, timeout: Keyword.fetch!(opts, :timeout)}
  end

  @doc false
  @spec repos(term()) :: Result.t([module()], String.t())

  def repos(value) do
    if is_list(value) and value != [] and Enum.all?(value, &repo?/1),
      do: {:ok, value},
      else: {:error, "ожидается непустой список модулей с `use Ecto.Repo`, получено #{inspect(value)}"}
  end

  # ---

  defp repo?(repo) do
    is_atom(repo) and Core.Helper.Module.exports?(repo, :__adapter__, 0)
  end

  defp path!(opts, key) do
    case Keyword.fetch!(opts, key) do
      "/" <> _ = path ->
        path

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.init/1: опция #{inspect(key)} — ожидается путь от корня, получено #{inspect(other)}"
    end
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
    case Enum.reject(check(repos || Config.ecto_repos(), timeout), &match?({_repo, :ok}, &1)) do
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
