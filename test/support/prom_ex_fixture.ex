defmodule Core.PromExFixture do
  @moduledoc """
  Модули PromEx приложения для рендера дашбордов подсистем библиотеки (`Core.PromEx.Dashboards`):
  с плагином outbox и порогами по умолчанию, такой же с другим и с длинным `otp_app`, со своим именем
  приложения в заголовке и с неверным его типом, с порогами и префиксом из `dashboard_assigns/0`, с
  префиксом и единицей длительности из опций плагина, без плагинов подсистем, без `datasource_id`, с
  плагинами es и cache; с плагинами процессов, памяти контейнера и внешних вызовов со своими опциями и
  порогами; с `Core.Mq.PromEx` и разными наборами опций читателей.
  """

  defmodule Outbox do
    @moduledoc "Плагин outbox, пороги по умолчанию."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [{Core.Outbox.PromEx, poll_rate: 5_000}, PromEx.Plugins.Beam]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus", default_selected_interval: "30s"]
  end

  defmodule OtherApp do
    @moduledoc "Как `Outbox`, но другой `otp_app`."

    use PromEx, otp_app: :other_app

    @impl true
    def plugins, do: [{Core.Outbox.PromEx, poll_rate: 5_000}, PromEx.Plugins.Beam]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus", default_selected_interval: "30s"]
  end

  defmodule LongApp do
    @moduledoc "Плагин outbox, `otp_app` длиннее лимита `uid` Grafana."

    use PromEx, otp_app: :an_application_with_a_name_longer_than_the_grafana_uid_limit

    @impl true
    def plugins, do: [Core.Outbox.PromEx]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus"]
  end

  defmodule AppTitle do
    @moduledoc "Как `Outbox`, но имя приложения в заголовке — из `dashboard_assigns/0`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [{Core.Outbox.PromEx, poll_rate: 5_000}, PromEx.Plugins.Beam]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus", default_selected_interval: "30s", app_title: "Мой сервис"]
  end

  defmodule BadAppTitle do
    @moduledoc "Имя приложения в заголовке — атом, а не строка."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [Core.Outbox.PromEx]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus", app_title: :my_service]
  end

  defmodule Tuned do
    @moduledoc "Плагин outbox без опций, пороги и префикс outbox — из `dashboard_assigns/0`."

    use PromEx, otp_app: :other_app

    @impl true
    def plugins, do: [Core.Outbox.PromEx]

    @impl true
    def dashboard_assigns do
      [
        datasource_id: "metrics",
        outbox_metric_prefix: "legacy_outbox",
        outbox_queue_warning: 7,
        outbox_queue_critical: 70,
        title: "чужой заголовок"
      ]
    end
  end

  defmodule Custom do
    @moduledoc "Плагин outbox со своими `metric_prefix:` и `duration_unit:`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [{Core.Outbox.PromEx, metric_prefix: [:custom, :outbox], duration_unit: :second}]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus"]
  end

  defmodule Bare do
    @moduledoc "Без плагинов подсистем библиотеки."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [PromEx.Plugins.Beam]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus"]
  end

  defmodule NoDatasource do
    @moduledoc "Без `datasource_id` в `dashboard_assigns/0`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [Core.Outbox.PromEx]
  end

  defmodule EsCache do
    @moduledoc "Плагины es и cache со своими `metric_prefix:`, у es — `duration_unit:`; пороги — из `dashboard_assigns/0`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins do
      [
        {Core.Es.PromEx, metric_prefix: [:custom, :es], duration_unit: :second},
        {Core.Cache.PromEx, sizes: {Function, :identity, [[]]}, metric_prefix: [:custom, :cache]}
      ]
    end

    @impl true
    def dashboard_assigns do
      [
        datasource_id: "prometheus",
        es_projection_lag_warning: 5,
        es_projection_lag_critical: 15,
        cache_hit_ratio_warning: 0.95,
        cache_hit_ratio_critical: 0.7
      ]
    end
  end

  defmodule Runtime do
    @moduledoc """
    Плагины процессов, памяти контейнера и внешних вызовов со своими опциями; пороги памяти и шаблон
    счётчиков сбоев сбора — из `dashboard_assigns/0`.
    """

    use PromEx, otp_app: :my_app

    @impl true
    def plugins do
      [
        {Core.Workers.PromEx, watch: {Kernel, :node, []}},
        {Core.Cgroup.PromEx, metric_prefix: [:custom, :cgroup]},
        {Core.External.PromEx, metric_prefix: [:custom, :external], duration_unit: :second}
      ]
    end

    @impl true
    def dashboard_assigns do
      [
        datasource_id: "prometheus",
        workers_container_memory_warning: 2_000_000_000,
        workers_container_memory_critical: 4_000_000_000,
        workers_collect_errors_pattern: "legacy_.+_collect_errors_total"
      ]
    end
  end

  defmodule MqStream do
    @moduledoc "`Core.Mq.PromEx` со `stream_readers:` и своими `metric_prefix:` и `duration_unit:`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins do
      [
        {Core.Mq.PromEx,
         stream_readers: {__MODULE__, :readers, []}, metric_prefix: [:custom, :mq], duration_unit: :second}
      ]
    end

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus"]
  end

  defmodule MqReaders do
    @moduledoc "`Core.Mq.PromEx` со старым ключом `readers:` без `stream_readers:`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [{Core.Mq.PromEx, readers: {__MODULE__, :readers, []}}]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus"]
  end

  defmodule MqKafka do
    @moduledoc "`Core.Mq.PromEx` с `kafka_readers:` и `dlq_repo:`, порог отставания — из `dashboard_assigns/0`."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [{Core.Mq.PromEx, kafka_readers: {__MODULE__, :readers, []}, dlq_repo: Core.TestRepo}]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus", kafka_backlog_critical: 5000]
  end

  defmodule MqBare do
    @moduledoc "`Core.Mq.PromEx` без читателей."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [Core.Mq.PromEx]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus"]
  end
end
