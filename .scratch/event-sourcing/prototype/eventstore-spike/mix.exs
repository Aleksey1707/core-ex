defmodule EventstoreSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :eventstore_spike,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EventstoreSpike.Application, []}
    ]
  end

  defp deps do
    [
      {:eventstore, "== 1.4.8"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.4"},
      {:jason, "== 1.4.5"}
    ]
  end
end
