defmodule Mix.Tasks.Mq.Dlq.Requeue do
  @shortdoc "Вернуть записи DLQ в Postgres в обработку"

  @moduledoc """
  Возврат записей `mq_dlq` из `dead` в `requeued` (`Core.Mq.Dlq`): их перечитывает
  `Core.Mq.Dlq.Reader` своего топика.

      mix mq.dlq.requeue --all
      mix mq.dlq.requeue --topic orders
      mix mq.dlq.requeue --id 42 --id 43
      mix mq.dlq.requeue --all --repo MyApp.OtherRepo

  `--all`, `--topic` и `--id` взаимоисключающи; `--id` повторяется. Порядок относительно уже
  обработанных сообщений исходного топика не восстанавливается.

  Репозиторий — `--repo`, по умолчанию `Core.Config.dao/0`. Задача загружает конфигурацию
  потребителя (`app.config`), поэтому запускается из его корня, но приложение не стартует:
  на время команды поднимается только репозиторий (`Ecto.Migrator.with_repo/2`), и команда
  работает рядом с запущенным сервером — без его портов, читателей и поллеров. Записи
  перечитывает уже работающий узел. В релизе без Mix — `Core.Mq.Dlq.Release.requeue/2`.
  """

  use Mix.Task

  alias Core.Config
  alias Core.Mq
  alias Core.Mq.Dlq

  @switches [all: :boolean, topic: :string, id: :keep, repo: :string]

  @doc false
  @impl Mix.Task
  def run(argv) when is_list(argv) do
    {target, repo} = parse!(argv)
    Mix.Task.run("app.config")

    {:ok, count, _apps} = Ecto.Migrator.with_repo(resolve_repo!(repo), &Dlq.requeue(&1, target))

    Mix.shell().info("Возвращено в обработку: #{count}")
  end

  @doc """
  Разобрать аргументы в цель `Core.Mq.Dlq.requeue/2` и имя репозитория из `--repo` (`nil` — не
  задан).
  """
  @spec parse!([String.t()]) :: {Dlq.target(), String.t() | nil}

  def parse!(argv) when is_list(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    target =
      case {Keyword.get(opts, :all, false), Keyword.get(opts, :topic), Keyword.get_values(opts, :id)} do
        {true, nil, []} -> :all
        {false, topic, []} when is_binary(topic) -> {:topic, parse_topic!(topic)}
        {false, nil, [_ | _] = ids} -> Enum.map(ids, &parse_id!/1)
        {false, nil, []} -> Mix.raise("укажите --all, --topic или хотя бы один --id")
        _other -> Mix.raise("--all, --topic и --id взаимоисключающи")
      end

    {target, Keyword.get(opts, :repo)}
  end

  # ---

  defp parse_topic!(raw) do
    case Mq.Topic.new(raw) do
      {:ok, topic} -> topic
      {:error, error} -> Mix.raise("--topic #{raw}: #{error.message}")
    end
  end

  defp parse_id!(raw) do
    case Integer.parse(raw) do
      {id, ""} when id > 0 -> id
      _other -> Mix.raise("--id #{raw}: ожидается положительное целое")
    end
  end

  # Модуль репозитория известен только после `app.config`: до загрузки приложения атома имени
  # может не быть.
  defp resolve_repo!(nil), do: Config.dao()

  defp resolve_repo!(raw) do
    Module.safe_concat([raw])
  rescue
    ArgumentError -> Mix.raise("--repo #{raw}: модуль не найден")
  end
end
