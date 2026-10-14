defmodule Mix.Tasks.Outbox.Requeue do
  @shortdoc "Вернуть проваленные записи outbox в очередь"

  @moduledoc """
  Возврат записей outbox из `:failed` в `:new` (шаг 3 runbook'а, `docs/rules/app/14-events-outbox.md`).

      mix outbox.requeue --all
      mix outbox.requeue --id 0199c0e2-... --id 0199c0e3-...

  `attempts` сбрасывается, аренда снимается, история ошибок очищается — причину читают
  до запуска, из колонки `errors` и логов поллера.

  Порядок доставки для возвращённых записей не восстанавливается: сообщения, шедшие за
  ними, уже опубликованы.

  Репозиторий берётся из `Core.Config.outbox_repo/0`. Задача загружает конфигурацию потребителя
  (`app.config`), поэтому запускается из его корня, но приложение не стартует: на время команды
  поднимается только `Core.Config.dao/0` (`Ecto.Migrator.with_repo/2`), и команда работает рядом
  с запущенным сервером — без его портов, читателей и поллеров. Записи забирает уже работающий
  поллер.
  """

  use Mix.Task

  alias Core.Config
  alias Core.Context
  alias Core.Outbox

  @switches [all: :boolean, id: :keep]

  @doc false
  @impl Mix.Task
  def run(argv) when is_list(argv) do
    target = parse_target!(argv)
    Mix.Task.run("app.config")

    repo = Config.outbox_repo()

    {:ok, count, _apps} =
      Ecto.Migrator.with_repo(Config.dao(), fn _dao -> repo.requeue_failed(target, Context.new()) end)

    Mix.shell().info("Возвращено в очередь: #{count}")
  end

  @doc """
  Разобрать аргументы в цель `requeue_failed/2`.

  `--all` и `--id` взаимоисключающи; `--id` повторяется.
  """
  @spec parse_target!([String.t()]) :: :all | [Outbox.ID.t()]

  def parse_target!(argv) when is_list(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    case {Keyword.get(opts, :all, false), Keyword.get_values(opts, :id)} do
      {true, []} -> :all
      {false, [_ | _] = ids} -> Enum.map(ids, &parse_id!/1)
      {true, [_ | _]} -> Mix.raise("--all и --id взаимоисключающи")
      {false, []} -> Mix.raise("укажите --all или хотя бы один --id")
    end
  end

  # ---

  defp parse_id!(raw) do
    case Outbox.ID.new(raw) do
      {:ok, id} -> id
      {:error, error} -> Mix.raise("--id #{raw}: #{error.message}")
    end
  end
end
