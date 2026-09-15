defmodule Core.Es.Projection.Registry do
  @moduledoc """
  Registry сигналов проекций внутри ноды (`keys: :duplicate`). Ключ — кортеж с видом сигнала, поэтому
  тип агрегата и имя проекции, совпавшие строкой, не будят чужих получателей:

  - сигнал записи — `{:written, <тип агрегата>}`: `Core.Es.Store.append/5` после commit будит
    `wake/1` читателей типа агрегата пачки;
  - пробуждение читателя — `{:awaited, <имя проекции>}`: ожидающий `Core.Es.Projection.await/4` на
    каждом шаге будит `wake_projection/1` читателя своей проекции;
  - сигнал чекпоинта — `{:checkpoint, <имя проекции>}`: читатель после commit пачки с исходом
    `:processed` и слушатель канала на уведомление пачки любой ноды
    (`Core.Es.Projection.Listener`) рассылают `signal_checkpoint/1` ожидающим проекции.

  Читатель (`Core.Es.Projection.Reader`) в `init/1` регистрируется под типами агрегатов из
  `events:` (`register/1`) и под именем своей проекции (`register_projection/1`); оба сигнала
  приходят ему сообщением `:wake`.

  Ожидающий подписывается на сигнал чекпоинта на время ожидания (`subscribe_checkpoint/1`):
  значение записи — alias процесса (`Process.alias/1`), сигнал идёт на alias.
  `unsubscribe_checkpoint/2` снимает запись и alias и вычерпывает доставленные сигналы: поздний
  сигнал runtime отбрасывает, и mailbox вызывающего — GenServer, LiveView — остаётся чистым.

  Процесс — первое звено `Core.Es.Projection.Supervisor` под именем этого модуля, поэтому второй
  супервизор на ноде не стартует. Registry не запущен — отправка отдаёт `:ok`, подписка
  пропускается.
  """

  # ===== регистрация =====

  @doc "Спецификация для Supervisor: `Registry` с `keys: :duplicate` под именем модуля."
  @spec child_spec(keyword()) :: Supervisor.child_spec()

  def child_spec(opts) when is_list(opts),
    do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc false
  @spec register([String.t()]) :: :ok

  def register(types) when is_list(types),
    do: Enum.each(types, &register_key({:written, &1}))

  @doc false
  @spec register_projection(String.t()) :: :ok

  def register_projection(name) when is_binary(name), do: register_key({:awaited, name})

  # ---

  defp register_key(key) do
    {:ok, _owner} = Registry.register(__MODULE__, key, nil)
    :ok
  end

  # ===== подписка ожидающего =====

  @doc false
  @spec subscribe_checkpoint(String.t()) :: reference()

  def subscribe_checkpoint(name) when is_binary(name) do
    subscription = Process.alias()
    :ok = register_subscription(name, subscription)
    subscription
  end

  @doc false
  @spec receive_checkpoint(reference(), non_neg_integer()) :: :signal | :timeout

  def receive_checkpoint(subscription, timeout)
      when is_reference(subscription) and is_integer(timeout) and timeout >= 0 do
    receive do
      {^subscription, :checkpoint} -> :signal
    after
      timeout -> :timeout
    end
  end

  @doc false
  @spec unsubscribe_checkpoint(String.t(), reference()) :: :ok

  def unsubscribe_checkpoint(name, subscription)
      when is_binary(name) and is_reference(subscription) do
    :ok = unregister_subscription(name)
    _active? = Process.unalias(subscription)
    flush_checkpoints(subscription)
  end

  # ---

  defp register_subscription(name, subscription) do
    {:ok, _owner} = Registry.register(__MODULE__, {:checkpoint, name}, subscription)
    :ok
  rescue
    # Registry не запущен — сигнала не будет, ожидание идёт шагами.
    ArgumentError -> :ok
  end

  defp unregister_subscription(name) do
    Registry.unregister(__MODULE__, {:checkpoint, name})
  rescue
    # Registry остановлен за время ожидания — запись ушла вместе с ним.
    ArgumentError -> :ok
  end

  defp flush_checkpoints(subscription) do
    receive do
      {^subscription, :checkpoint} -> flush_checkpoints(subscription)
    after
      0 -> :ok
    end
  end

  # ===== отправка =====

  @doc false
  @spec wake(String.t()) :: :ok

  def wake(type) when is_binary(type), do: dispatch({:written, type}, &send_wake/1)

  @doc false
  @spec wake_projection(String.t()) :: :ok

  def wake_projection(name) when is_binary(name), do: dispatch({:awaited, name}, &send_wake/1)

  @doc false
  @spec signal_checkpoint(String.t()) :: :ok

  def signal_checkpoint(name) when is_binary(name),
    do: dispatch({:checkpoint, name}, &send_checkpoint/1)

  # ---

  defp dispatch(key, send_entries) do
    Registry.dispatch(__MODULE__, key, send_entries)
  rescue
    # Registry не запущен или остановлен до рассылки — будить некого.
    ArgumentError -> :ok
  end

  defp send_wake(entries), do: Enum.each(entries, fn {pid, nil} -> send(pid, :wake) end)

  # Сигнал идёт на alias: после снятия подписки runtime его отбрасывает.
  defp send_checkpoint(entries) do
    Enum.each(entries, fn {_pid, subscription} ->
      send(subscription, {subscription, :checkpoint})
    end)
  end
end
