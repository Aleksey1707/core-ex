defmodule Core.Es.Projection.Registry do
  @moduledoc """
  Registry читателей проекций (`keys: :duplicate`) — адресат `wake` после commit
  `Core.Es.Store.append/5`.

  Читатель (`Core.Es.Projection.Reader`) в `init/1` регистрируется под типами агрегатов из
  `events:` своей проекции, а `append` будит всех читателей типа агрегата пачки. Процесс — первое
  звено `Core.Es.Projection.Supervisor` под именем этого модуля, поэтому второй супервизор на ноде
  не стартует. Registry не запущен — `wake/1` отдаёт `:ok`.
  """

  @doc "Спецификация для Supervisor: `Registry` с `keys: :duplicate` под именем модуля."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts),
    do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc false
  @spec register([String.t()]) :: :ok

  def register(types) when is_list(types) do
    Enum.each(types, fn type -> {:ok, _owner} = Registry.register(__MODULE__, type, nil) end)
  end

  @doc false
  @spec wake(String.t()) :: :ok

  def wake(type) when is_binary(type) do
    Registry.dispatch(__MODULE__, type, &send_wake/1)
  rescue
    # Registry не запущен или остановлен до рассылки — будить некого.
    ArgumentError -> :ok
  end

  # ---

  defp send_wake(entries), do: Enum.each(entries, fn {pid, nil} -> send(pid, :wake) end)
end
