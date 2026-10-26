defmodule Core.PromExFixture do
  @moduledoc """
  Модули PromEx приложения для рендера дашбордов подсистем библиотеки (`Core.PromEx.Dashboards`):
  с плагином outbox и порогами по умолчанию, с порогами и префиксом из `dashboard_assigns/0`, с
  префиксом и единицей длительности из опций плагина, без плагинов подсистем, без `datasource_id`.
  """

  defmodule Outbox do
    @moduledoc "Плагин outbox, пороги по умолчанию."

    use PromEx, otp_app: :my_app

    @impl true
    def plugins, do: [{Core.Outbox.PromEx, poll_rate: 5_000}, PromEx.Plugins.Beam]

    @impl true
    def dashboard_assigns, do: [datasource_id: "prometheus", default_selected_interval: "30s"]
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
end
