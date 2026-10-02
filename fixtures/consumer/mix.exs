defmodule Consumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :consumer,
      version: "0.1.0",
      elixir: "~> 1.20",
      # Сценарии — намеренно ошибочный код, а не образец раскладки: `boundary_lint` проверяет только `lib/`.
      elixirc_paths: ["lib", "scenarios"],
      # Границы контекста держит сборка: предупреждения Boundary сверяются с маркерами наравне с остальными.
      compilers: [:boundary] ++ Mix.compilers(),
      # Версии зависимостей — ровно как у библиотеки: свой lock не дрейфует.
      lockfile: "../../mix.lock",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:core, path: "../.."},
      {:boundary, "~> 0.10", runtime: false},
      {:hackney, "~> 4.0.1", override: true}
    ]
  end
end
