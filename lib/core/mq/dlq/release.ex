defmodule Core.Mq.Dlq.Release do
  @moduledoc """
  Команда оператора DLQ для релиза, где Mix нет (`bin/my_app eval`).

  Приложение зовёт её из своей задачи релиза, загрузив конфигурацию:

      defmodule MyApp.Release do
        def dlq_requeue(target) do
          Application.load(:my_app)
          Core.Mq.Dlq.Release.requeue(MyApp.DAO, target)
        end
      end

      bin/my_app eval 'MyApp.Release.dlq_requeue(:all)'
      bin/my_app eval 'MyApp.Release.dlq_requeue({:topic, Core.Mq.Topic.new!("orders")})'
      bin/my_app eval 'MyApp.Release.dlq_requeue([42, 43])'

  Ответ оператору — `IO.puts`: Mix в релизе нет (`20-agreements.md`, «Логирование»). То же из
  корня приложения — `mix mq.dlq.requeue`.
  """

  alias Core.Mq.Dlq

  @doc """
  Вернуть записи `dead` в обработку (`Core.Mq.Dlq.requeue/2`) и сообщить их число.

  Репозиторий поднимается на время команды (`Ecto.Migrator.with_repo/2`), если ещё не запущен.
  """
  @spec requeue(Ecto.Repo.t(), Dlq.target()) :: :ok

  def requeue(repo, target) when is_atom(repo) do
    {:ok, count, _apps} = Ecto.Migrator.with_repo(repo, &Dlq.requeue(&1, target))

    IO.puts("Возвращено в обработку: #{count}")
  end
end
