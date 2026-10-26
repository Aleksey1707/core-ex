defmodule Core.PromEx.Dashboards do
  @moduledoc """
  Дашборды подсистем библиотеки: рендер шаблонов `priv/dashboards/*.json.eex` для модуля PromEx
  приложения (ADR-0089).

  Рендер идёт через `PromEx.DashboardRenderer`, как у штатных дашбордов PromEx. Параметры шаблона
  собираются по возрастанию приоритета:

  1. умолчания рендерера — префиксы штатных плагинов (`prom_ex_metric_prefix` и др.);
  2. умолчания библиотеки — префикс плагина подсистемы и пороги панелей (таблица ниже);
  3. `dashboard_assigns/0` модуля PromEx приложения.

  `otp_app` и `title` берутся из `use PromEx` приложения и имени дашборда; `dashboard_assigns/0` их не
  меняет: один ключ на все дашборды дал бы им общий заголовок. `uid` считает
  `__grafana_dashboard_uid__/3` модуля PromEx, как у штатных дашбордов: от `otp_app`, имени модуля
  PromEx, пути шаблона и заголовка — переименованный модуль даёт в Grafana новый дашборд.
  `datasource_id` — uid datasource Prometheus в Grafana, обязателен в `dashboard_assigns/0`,
  умолчания нет.

  Префикс метрик и единица длительности по умолчанию следуют опциям плагина подсистемы в
  `plugins/0` (`metric_prefix:`, `duration_unit:`), как имена метрик самого плагина.

  | Дашборд | Плагин | Параметр | Умолчание |
  |---|---|---|---|
  | `outbox` | `Core.Outbox.PromEx` | `outbox_metric_prefix` | `metric_prefix:` плагина, `"<otp_app>_prom_ex_outbox"` |
  | | | `outbox_duration_unit` | `duration_unit:` плагина (мн. ч.) или `"milliseconds"` |
  | | | `outbox_queue_warning` / `outbox_queue_critical` | `100` / `500` записей |
  | | | `outbox_oldest_age_warning` / `outbox_oldest_age_critical` | `30` / `120` секунд |
  | | | `outbox_expired_locks_warning` / `outbox_expired_locks_critical` | `1` / `10` записей |

  Выгрузку в каталог дашбордов приложения делает `mix core.dashboards.export`.
  """

  alias PromEx.DashboardRenderer

  @typedoc "Имя дашборда подсистемы библиотеки; файл выгрузки — `<имя>.json`."
  @type name :: :outbox

  @dashboards [outbox: %{plugin: Core.Outbox.PromEx, label: "Outbox"}]
  @names Keyword.keys(@dashboards)

  # ===== набор =====

  @doc "Все дашборды подсистем библиотеки."
  @spec names() :: [name()]

  def names, do: @names

  @doc """
  Набор дашбордов по умолчанию для модуля PromEx приложения — по его `plugins/0`.

  Дашборд входит в набор, если в `plugins/0` есть плагин его подсистемы.
  """
  @spec defaults(module()) :: [name()]

  def defaults(prom_ex) when is_atom(prom_ex) do
    plugins = plugins(prom_ex)
    for {name, %{plugin: plugin}} <- @dashboards, Map.has_key?(plugins, plugin), do: name
  end

  # ===== рендер =====

  @doc """
  Отрендерить дашборд `name` для модуля PromEx приложения — JSON выгрузки.

  `ArgumentError` — в `dashboard_assigns/0` нет `datasource_id` или параметры дали невалидный JSON.
  """
  @spec render(module(), name()) :: String.t()

  def render(prom_ex, name) when is_atom(prom_ex) and name in @names do
    otp_app = prom_ex.__otp_app__()
    %{plugin: plugin, label: label} = Keyword.fetch!(@dashboards, name)
    plugin_opts = Map.get(plugins(prom_ex), plugin, [])

    :core
    |> DashboardRenderer.build("dashboards/#{name}.json", otp_app)
    |> DashboardRenderer.merge_assigns(library_assigns(name, otp_app, plugin_opts))
    |> DashboardRenderer.merge_assigns(prom_ex.dashboard_assigns())
    |> DashboardRenderer.merge_assigns(otp_app: otp_app, title: "#{Macro.camelize(Atom.to_string(otp_app))} - #{label}")
    |> check_datasource!(prom_ex)
    |> DashboardRenderer.render_dashboard(prom_ex)
    |> DashboardRenderer.decode_dashboard()
    |> rendered!(prom_ex, name)
  end

  # ---

  defp library_assigns(:outbox, otp_app, plugin_opts) do
    [
      outbox_metric_prefix: metric_prefix(plugin_opts, otp_app, :outbox),
      outbox_duration_unit: duration_unit(plugin_opts),
      outbox_queue_warning: 100,
      outbox_queue_critical: 500,
      outbox_oldest_age_warning: 30,
      outbox_oldest_age_critical: 120,
      outbox_expired_locks_warning: 1,
      outbox_expired_locks_critical: 10
    ]
  end

  defp metric_prefix(plugin_opts, otp_app, plugin) do
    plugin_opts
    |> Keyword.get(:metric_prefix, PromEx.metric_prefix(otp_app, plugin))
    |> Enum.join("_")
  end

  defp duration_unit(plugin_opts) do
    plugin_opts
    |> Keyword.get(:duration_unit, :millisecond)
    |> PromEx.Utils.make_plural_atom()
    |> Atom.to_string()
  end

  defp check_datasource!(%DashboardRenderer{assigns: assigns} = dashboard, prom_ex) do
    case Keyword.get(assigns, :datasource_id) do
      <<_, _::binary>> ->
        dashboard

      other ->
        raise ArgumentError,
              "Core.PromEx.Dashboards.render/2: #{inspect(prom_ex)}.dashboard_assigns/0 — ожидается " <>
                "datasource_id: uid datasource Prometheus строкой, получено #{inspect(other)}"
    end
  end

  defp rendered!(%DashboardRenderer{valid_json?: true, rendered_file: json}, _prom_ex, _name), do: json

  defp rendered!(%DashboardRenderer{error: error}, prom_ex, name) do
    raise ArgumentError,
          "Core.PromEx.Dashboards.render/2: дашборд #{name} для #{inspect(prom_ex)} не отрендерился: " <>
            inspect(error)
  end

  # ===== общее =====

  defp plugins(prom_ex), do: Map.new(prom_ex.plugins(), &plugin_entry/1)

  defp plugin_entry({plugin, plugin_opts}) when is_atom(plugin) and is_list(plugin_opts), do: {plugin, plugin_opts}
  defp plugin_entry(plugin) when is_atom(plugin), do: {plugin, []}
end
