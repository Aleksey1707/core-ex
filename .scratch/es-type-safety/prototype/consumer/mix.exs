defmodule Blind.MixProject do
  use Mix.Project

  def project do
    [
      app: :blind,
      version: "0.1.0",
      elixir: "~> 1.20",
      # Версии зависимостей — ровно как у core-ex: свой lock не дрейфует.
      lockfile: "../../../../mix.lock",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:core, path: "../../../.."},
      {:hackney, "~> 4.0.1", override: true}
    ]
  end
end
