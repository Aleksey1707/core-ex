defmodule Core.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :core,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix], ignore_warnings: "dialyzer.ignore.exs"],
      description: "Shared-фундамент приложений: Prim, Codec, Repo, Es, Outbox, MQ, PubSub",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Хранилище
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:jason, "~> 1.2"},
      {:uuid, "~> 1.1"},
      {:uuidv7, "~> 1.0"},
      # Наблюдаемость
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:prom_ex, "~> 1.11"},
      # Брокеры
      {:rabbitmq_stream, "~> 0.4.2"},
      {:klife, "~> 1.2"},
      # Криптография
      {:argon2_elixir, "~> 4.1"},
      {:fernetex, "~> 0.5"},
      {:plug_crypto, "~> 2.2"},
      # Нужен prom_ex: он компилирует `PromEx.Plug` безусловно, хотя plug у него optional
      {:plug, "~> 1.20"},
      # Транзитивная зависимость prom_ex; тот же override, что у потребителей
      {:hackney, "~> 4.0.1", override: true},
      #
      # База часовых поясов нужна только тестам библиотеки: потребитель выбирает
      # реализацию `config :elixir, :time_zone_database` сам.
      {:tzdata, github: "lau/tzdata", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end
end
