defmodule Core.PromEx.Labels do
  @moduledoc """
  Повтор метки в списке наблюдаемых процессов.

  Метку процесса (`component:`) задаёт строка из списка потребителя, а не зарегистрированное имя,
  и два элемента с одной меткой ничто не запрещает. `last_value` оставляет последнее значение, и
  живой процесс скрыл бы упавший. Поэтому плагин сводит элементы с одной меткой в одно значение
  (правило свёртки — у плагина: `up` — минимум), а повтор пишет в лог `error` — один раз на набор
  повторов источника на ноде, а не на каждом опросе. Источник — экземпляр плагина (его MFA списка):
  два экземпляра одного плагина помнят свои наборы раздельно, а порядок элементов в списке набор не
  меняет.
  """

  require Logger

  @doc "Сгруппировать элементы по метке в порядке первого появления."
  @spec group([item], (item -> key)) :: [{key, [item, ...]}] when item: map(), key: term()

  def group(items, label) when is_list(items) and is_function(label, 1) do
    {order, groups} =
      Enum.reduce(items, {[], %{}}, fn item, {order, groups} ->
        key = label.(item)

        case groups do
          %{^key => same} -> {order, %{groups | key => [item | same]}}
          %{} -> {[key | order], Map.put(groups, key, [item])}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&{&1, Enum.reverse(Map.fetch!(groups, &1))})
  end

  @doc """
  Записать в лог повторы меток: `error`, если набор повторов источника `source` изменился.

  Элементы групп несут `name:` — имя процесса, оно попадает в лог.
  """
  @spec report(String.t(), [{term(), [%{name: GenServer.name()}, ...]}]) :: :ok

  def report(source, groups) when is_binary(source) and is_list(groups) do
    repeated =
      groups
      |> Enum.filter(&match?({_key, [_, _ | _]}, &1))
      |> Enum.map(fn {key, items} -> {key, Enum.sort(Enum.map(items, & &1.name))} end)
      |> Enum.sort()

    known = {__MODULE__, source}

    if repeated != :persistent_term.get(known, []) do
      :persistent_term.put(known, repeated)
      log_repeated(source, repeated)
    end

    :ok
  end

  # ---

  defp log_repeated(_source, []), do: :ok

  defp log_repeated(source, repeated) do
    Logger.error(
      "PromEx: метка повторяется, значения сведены: source=#{source} " <>
        "labels=#{Enum.map_join(repeated, "; ", fn {key, names} -> "#{inspect(key)}=#{inspect(names)}" end)}"
    )
  end
end
