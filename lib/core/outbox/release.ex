defmodule Core.Outbox.Release do
  @moduledoc """
  Команда оператора outbox для релиза, где Mix нет (`bin/my_app eval`).

  Приложение зовёт её из своей задачи релиза, загрузив конфигурацию:

      defmodule MyAppApp.Release do
        def outbox_requeue(target) do
          Application.load(:my_app)
          Core.Outbox.Release.requeue(target)
        end
      end

      bin/my_app eval 'MyAppApp.Release.outbox_requeue(:all)'
      bin/my_app eval 'MyAppApp.Release.outbox_requeue([Core.Outbox.ID.new!("0199c0e2-...")])'

  Ответ оператору — `IO.puts`: Mix в релизе нет (`20-agreements.md`, «Логирование»). То же из
  корня приложения — `mix outbox.requeue`.
  """

  alias Core.Config
  alias Core.Context
  alias Core.Outbox

  @doc """
  Вернуть `:failed`-записи в очередь (`requeue_failed/2` репозитория `Core.Config.outbox_repo/0`) и
  сообщить их число.

  На время команды поднимается `Core.Config.dao/0` (`Ecto.Migrator.with_repo/2`), если ещё не
  запущен; записи забирает уже работающий поллер.
  """
  @spec requeue(:all | [Outbox.ID.t()]) :: :ok

  def requeue(:all), do: requeue_failed(:all)
  def requeue(ids) when is_list(ids), do: requeue_failed(ids)

  # ---

  defp requeue_failed(target) do
    repo = Config.outbox_repo()

    {:ok, count, _apps} =
      Ecto.Migrator.with_repo(Config.dao(), fn _dao -> repo.requeue_failed(target, Context.new()) end)

    IO.puts("Возвращено в очередь: #{count}")
  end
end
