defmodule Mix.Tasks.Es.Personal.Rewrap do
  @shortdoc "Перевернуть ключи субъектов на текущий KEK"

  @moduledoc """
  Перевёртка обёрток ключей субъектов встроенного хранилища на текущий KEK — шаг 3 ротации KEK
  (`docs/rules/app/23-personal-data.md`, «Ротация KEK»).

      mix es.personal.rewrap
      mix es.personal.rewrap --batch-size 100

  Печатает статус (`Core.Es.Personal.KeyStore.Pg.status/0`) — живые ключи по версиям KEK, —
  перевёртывает (`Core.Es.Personal.KeyStore.Pg.rewrap/1`) с прогрессом после каждой пачки и
  печатает статус снова. `--batch-size` — размер пачки, по умолчанию 500. Прерванный прогон
  продолжается повторным запуском. Старая версия удаляется из `keks:`, когда под ней ноль.

  Задача загружает конфигурацию потребителя (`app.config`), поэтому запускается из его корня, но
  приложение не стартует: на время команды поднимается только `Core.Config.dao/0`
  (`Ecto.Migrator.with_repo/2`), и команда работает рядом с запущенным сервером. В релизе без
  Mix — `rewrap/1` и `status/0` из задачи релиза приложения через `bin/my_app eval`.
  """

  use Mix.Task

  alias Core.Config
  alias Core.Error
  alias Core.Es.Personal.KeyStore.Pg

  @switches [batch_size: :integer]

  # ===== запуск =====

  @doc false
  @impl Mix.Task
  def run(argv) when is_list(argv) do
    opts = parse_opts!(argv)
    Mix.Task.run("app.config")

    {:ok, result, _apps} = Ecto.Migrator.with_repo(Config.dao(), fn _dao -> rewrap(opts) end)

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> Mix.raise("перевёртка прервана: #{describe(error)}")
    end
  end

  # ---

  defp rewrap(opts) do
    with :ok <- print_status(),
         {:ok, count} <- Pg.rewrap([on_batch: &progress/1] ++ opts) do
      Mix.shell().info("Перевёрнуто ключей: #{count}")
      print_status()
    end
  end

  defp progress(total), do: Mix.shell().info("перевёрнуто: #{total}")

  defp print_status do
    with {:ok, status} <- Pg.status() do
      for {version, count} <- Enum.sort(status), do: Mix.shell().info("KEK #{version}: #{count}")

      :ok
    end
  end

  defp describe(%Error{ns: ns, code: code, message: message, detail: detail}),
    do: "#{ns}/#{code} #{message} #{inspect(detail)}"

  # ===== аргументы =====

  @doc """
  Разобрать аргументы в опции `Core.Es.Personal.KeyStore.Pg.rewrap/1`.

  `--batch-size` — положительное целое.
  """
  @spec parse_opts!([String.t()]) :: keyword()

  def parse_opts!(argv) when is_list(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    case Keyword.fetch(opts, :batch_size) do
      {:ok, size} when size > 0 -> [batch_size: size]
      {:ok, size} -> Mix.raise("--batch-size — положительное целое, задано #{size}")
      :error -> []
    end
  end
end
