defmodule Mix.Tasks.Core.Dashboards.Export do
  @shortdoc "Выгрузить дашборды подсистем библиотеки в каталог дашбордов приложения"

  @moduledoc """
  Рендер дашбордов подсистем библиотеки (`Core.PromEx.Dashboards`) для модуля PromEx приложения
  в каталог дашбордов Grafana (ADR-0089).

      mix core.dashboards.export --module MyAppApp.PromEx
      mix core.dashboards.export --module MyAppApp.PromEx --dashboard outbox --out priv/grafana

  - `--module` — модуль `use PromEx` приложения, обязателен;
  - `--dashboard` — имя дашборда, повторяется; без него — набор по умолчанию по `plugins/0` модуля;
  - `--out` — каталог выгрузки, по умолчанию `deploy/monitoring/grafana/dashboards`.

  Файл выгрузки — `<имя дашборда>.json`, существующий перезаписывается. Выгрузку руками не правят:
  пороги и datasource задаёт `dashboard_assigns/0` модуля PromEx, после обновления core дашборды
  выгружаются заново. Задача загружает конфигурацию приложения (`app.config`) и запускается из его
  корня; приложение не стартует.
  """

  use Mix.Task

  alias Core.Helper
  alias Core.PromEx.Dashboards

  @switches [module: :string, dashboard: :keep, out: :string]
  @default_out "deploy/monitoring/grafana/dashboards"

  @doc false
  @spec run([String.t()]) :: :ok

  @impl Mix.Task
  def run(argv) when is_list(argv) do
    {switches, _rest} = OptionParser.parse!(argv, strict: @switches)
    raw_module = Keyword.get(switches, :module) || Mix.raise("укажите --module — модуль use PromEx приложения")
    Mix.Task.run("app.config")

    prom_ex = prom_ex!(raw_module)
    out = Keyword.get(switches, :out, @default_out)

    case dashboards!(Keyword.get_values(switches, :dashboard), prom_ex) do
      [] ->
        Mix.shell().info(
          "Для #{inspect(prom_ex)} нет дашбордов подсистем библиотеки: " <>
            "в plugins/0 нет их плагинов или опций, которых они требуют"
        )

      names ->
        Enum.each(names, &export(prom_ex, &1, out))
    end
  end

  # ---

  defp prom_ex!(raw) do
    module = existing_module(raw)

    if module && Helper.Module.exports?(module, :__otp_app__, 0) &&
         Helper.Module.exports?(module, :dashboard_assigns, 0),
       do: module,
       else: Mix.raise("--module #{raw}: модуль PromEx не найден")
  end

  defp existing_module(raw) do
    Module.safe_concat([raw])
  rescue
    ArgumentError -> nil
  end

  defp dashboards!([], prom_ex), do: Dashboards.defaults(prom_ex)
  defp dashboards!(raw_names, _prom_ex), do: Enum.map(Enum.uniq(raw_names), &dashboard!/1)

  defp dashboard!(raw) do
    names = Dashboards.names()

    Enum.find(names, &(Atom.to_string(&1) == raw)) ||
      Mix.raise("--dashboard #{raw}: нет такого дашборда, есть #{Enum.join(names, ", ")}")
  end

  defp export(prom_ex, name, out) do
    path = Path.join(out, "#{name}.json")
    File.mkdir_p!(out)
    File.write!(path, Dashboards.render(prom_ex, name))
    Mix.shell().info("Выгружен дашборд #{name}: #{path}")
  end
end
