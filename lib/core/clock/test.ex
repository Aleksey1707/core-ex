defmodule Core.Clock.Test do
  @moduledoc """
  Тестовые часы: реализация `Core.Clock`, которая останавливает и сдвигает доменное время
  процесса-владельца (ADR-0083).

  Подключение — строка конфигурации и старт сервера владения:

      # config/test.exs
      config :core, clock: Core.Clock.Test

      # test/test_helper.exs
      :ok = Core.Clock.Test.start()

  Время останавливает `freeze/1` процесса теста. Его видят сам владелец и процессы, у которых он
  в `$callers` (`Task`), без настройки. Остальным время владельца открывает `allow/2`, всем
  процессам VM — `global/0`. Не нашёлся владелец — реальное время, поэтому тесту без часов
  настраивать нечего, а параллельные тесты друг друга не видят. Владение снимается при выходе
  процесса-владельца.
  """

  @behaviour Core.Clock

  @server __MODULE__
  @key :now

  # ===== управление =====

  @doc "Запустить сервер владения; зовётся один раз в `test_helper.exs`, повторный вызов — `:ok`."
  @spec start() :: :ok

  def start do
    case NimbleOwnership.start_link(name: @server) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Остановить время процесса на моменте `at`: он приводится к UTC с микросекундами.

  Владелец — вызывающий процесс: `freeze/1` и `advance/1` в `Task` теста останавливают время самого
  `Task`, а не теста.
  """
  @spec freeze(DateTime.t()) :: :ok

  def freeze(%DateTime{} = at) do
    at = utc_usec(at)
    update!(fn _current -> {:ok, at} end)
  end

  @doc """
  Сдвинуть остановленное время процесса на `duration` — `Duration` или keyword `DateTime.shift/2`.

  Без `freeze/1` — `ArgumentError`: сдвигать нечего, детерминированного момента у теста нет.
  """
  @spec advance(Duration.t() | Duration.duration()) :: :ok

  def advance(%Duration{} = duration) do
    case update!(&shift(&1, duration)) do
      :ok -> :ok
      :not_frozen -> raise ArgumentError, "Core.Clock.Test.advance/1: время процесса не остановлено, сначала freeze/1"
    end
  end

  def advance(duration) when is_list(duration), do: advance(Duration.new!(duration))

  @doc """
  Открыть время, которое видит `owner`, процессу `allowed`, которого нет в его `$callers`: реактору,
  подписчику, `GenServer`. `allowed` — pid или функция, которая вернёт pid к первому чтению.

  `owner` — сам владелец или процесс с доступом к его времени: `Task` теста (`self()` — с его
  `$callers`) открывает время теста. Ни владельца, ни доступа у `owner` нет — он становится
  владельцем: MAY до `freeze/1`, и до остановки процесс видит реальное время, после — время
  владельца.
  """
  @spec allow(pid(), pid() | (-> pid() | [pid()])) :: :ok

  def allow(owner, allowed) when is_pid(owner) and (is_pid(allowed) or is_function(allowed, 0)) do
    case NimbleOwnership.allow(@server, access(owner), allowed, @key) do
      :ok ->
        :ok

      {:error, %NimbleOwnership.Error{reason: :not_allowed}} ->
        {:ok, :ok} = NimbleOwnership.get_and_update(@server, owner, @key, &{:ok, &1 || :real})
        allow(owner, allowed)

      {:error, %NimbleOwnership.Error{} = error} ->
        raise error
    end
  end

  @doc """
  Глобальный режим: время процесса видят все процессы VM — только тесту с `async: false`.

  `allow/2` в нём не нужен и даёт ошибку. Выход процесса возвращает частный режим.
  """
  @spec global() :: :ok

  def global, do: NimbleOwnership.set_mode_to_shared(@server, self())

  # ---

  defp access(pid) do
    case owner(callers(pid)) do
      {:ok, owner} -> owner
      :error -> pid
    end
  end

  # Метаданные владельца: остановленный момент или `:real` — владение без остановки (`allow/2` до
  # `freeze/1`): метаданные `nil` библиотека владения владением не считает.
  defp update!(fun) do
    case NimbleOwnership.get_and_update(@server, self(), @key, fun) do
      {:ok, result} -> result
      {:error, %NimbleOwnership.Error{} = error} -> raise error
    end
  end

  # Колбэк исполняется в сервере владения: исключение здесь уронило бы его для всех тестов.
  defp shift(%DateTime{} = at, duration), do: {:ok, DateTime.shift(at, duration)}
  defp shift(real, _duration) when real in [nil, :real], do: {:not_frozen, :real}

  defp utc_usec(%DateTime{} = at) do
    %DateTime{microsecond: {us, _}} = utc = DateTime.shift_zone!(at, "Etc/UTC")
    %{utc | microsecond: {us, 6}}
  end

  # ===== чтение =====

  @doc "Доменное «сейчас» процесса: время владельца из `self()`, `$callers` или разрешений, иначе реальное."
  @spec now() :: DateTime.t()

  @impl true
  def now do
    case owner(callers(self())) do
      {:ok, owner} -> owner_time(owner)
      :error -> Core.Clock.System.now()
    end
  end

  # ---

  defp owner_time(owner) do
    case NimbleOwnership.get_owned(@server, owner, %{}) do
      %{@key => %DateTime{} = at} -> at
      _ -> Core.Clock.System.now()
    end
  end

  # ===== общее =====

  # `$callers` известны только у своего процесса: чужой pid ищется сам по себе.
  defp callers(pid) when pid == self(), do: [pid | Process.get(:"$callers", [])]
  defp callers(pid), do: [pid]

  defp owner(callers) do
    case NimbleOwnership.fetch_owner(@server, callers, @key) do
      {:ok, owner} -> {:ok, owner}
      {:shared_owner, owner} -> {:ok, owner}
      :error -> :error
    end
  end
end
