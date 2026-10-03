defmodule Core.Outbox.Supervisor.Mark do
  @moduledoc """
  Отметка дерева очереди на ноде — имена и фильтры топиков поллеров `Core.Outbox.Supervisor` в
  `:persistent_term`. Ставит старт дерева до подъёма детей, при `:ignore` — пустой список; читают
  wake после вставки (`Core.Outbox.Repo.Pg`) и `init/1` поллера.

  Отметка — отдельный модуль, а не функция супервизора: дерево зависит от поллера, и проверка
  поллером отметки через супервизор замкнула бы цикл модулей.
  """

  @typedoc "Поллер дерева: имя процесса и фильтр топиков."
  @type poller :: {atom(), Core.Outbox.topics_filter()}

  @doc false
  @spec put([poller()]) :: :ok

  def put(pollers) when is_list(pollers), do: :persistent_term.put(__MODULE__, pollers)

  @doc false
  @spec pollers() :: [poller()]

  def pollers, do: :persistent_term.get(__MODULE__, [])

  @doc false
  @spec member?(atom()) :: boolean()

  def member?(name) when is_atom(name), do: List.keymember?(pollers(), name, 0)
end
