defmodule Core.Labels.Refs do
  @moduledoc """
  Словарь ссылок страницы событий: текущее имя каждого id с резолвером, упомянутого на странице
  (ADR-0063).

  Usecase страницы событий собирает его одним вызовом от страницы и контекста:

      with :ok <- check_access(id, context),
           {:ok, page} <- @repo.page_stream(id, limit, offset, context),
           {:ok, refs} <- Core.Labels.Refs.get(page, context),
           do: {:ok, {page, refs}}

  Id с резолвером — Prim-идентификатор с `use Core.Labels.ID` вида `:ref` или `:user`. Сборщик
  находит его у автора события и на любой глубине нагрузки: в struct'ах, ключах и значениях map'ы и
  словаря, списках, множествах, нагрузке-семействе, Prim-композите. Остальные поля события
  (`aggregate_id`, `id`) в сведения не выходят и не обходятся.

  Обход нагрузки — общий со сведениями (`Core.Labels.Walk.values/2`): видимые поля по объявлению
  (`Core.Labels.Fields`), у варианта семейства — его поля, у struct'а изменения — стороны `old_value`
  и `new_value`, у контейнеров — элементы и пары своих видов. Скрытое поле в обход не попадает, и
  резолвер его не получает. `text:` выходит листом: id в нём ссылкой не выходит. Struct без
  объявления полей обходится целиком.

  Словарь не шире сведений: каждый его id, кроме автора события, есть в сведениях. В `Date`,
  `DateTime`, `NaiveDateTime`, `Time`, `Decimal`, Prim без вида id, id `kind: :id` и Prim с
  `Core.Labels.Text` ссылки нет: id там нет или он не выходит ссылкой.

  Id группируются по резолверу, и резолвер (`Core.Labels.Resolver`) вызывается один раз на группу
  пачкой уникальных id. Без id с резолвером — `{:ok, %{}}` без вызовов. Отказ резолвера — итог; у
  записи без имени — `nil`.
  """

  alias Core.Context
  alias Core.Es
  alias Core.Es.Personal.Destroyed
  alias Core.Labels.Fields
  alias Core.Labels.Kind
  alias Core.Labels.Walk
  alias Core.Pagination
  alias Core.Result

  @typedoc "Словарь ссылок: имя по id, у записи без имени — `nil`."
  @type t :: %{struct() => String.t() | nil}

  @doc "Словарь ссылок страницы событий, списка событий или события."
  @spec get(Pagination.Result.t(Es.Event.t()) | [Es.Event.t()] | Es.Event.t(), Context.t()) :: Result.t(t())

  def get(%Pagination.Result{items: events}, %Context{} = context), do: get(events, context)

  def get(events, %Context{} = context) when is_list(events) do
    groups =
      Enum.reduce(events, %{}, fn %_{payload: payload, by: by}, groups -> visit(payload, visit(by, groups)) end)

    groups
    |> Map.to_list()
    |> Result.traverse(fn {resolver, ids} -> resolver.get_names(MapSet.to_list(ids), context) end)
    |> Result.map(&Enum.reduce(&1, %{}, fn names, refs -> Map.merge(refs, names) end))
  end

  def get(%_{payload: _, by: _} = event, %Context{} = context), do: get([event], context)

  # ---

  # Prim — ссылка сама, объявленный struct — видимая форма (та же, что у сведений), прочее — мимо.
  defp visit(%module{} = value, groups) do
    cond do
      Core.Prim.prim?(module) -> prim(module, value, groups)
      module in Kind.scalars() -> groups
      Fields.labelled?(module) -> walk(Walk.values(module, value), groups)
      true -> raw(Map.from_struct(value), groups)
    end
  end

  defp visit(_value, groups), do: groups

  # Struct без объявления полей обходится целиком: поля, списки, множества и пары map'ы.
  defp raw(%MapSet{} = set, groups), do: raw(MapSet.to_list(set), groups)
  defp raw(%_{} = value, groups), do: visit(value, groups)

  defp raw(map, groups) when is_map(map),
    do: Enum.reduce(map, groups, fn {key, value}, acc -> raw(value, raw(key, acc)) end)

  defp raw(list, groups) when is_list(list), do: Enum.reduce(list, groups, &raw/2)
  defp raw(_term, groups), do: groups

  defp walk({:fields, nodes}, groups), do: Enum.reduce(nodes, groups, &entry/2)
  defp walk({:change, node}, groups), do: entry(node, groups)

  defp entry(%{data: :leaf} = node, groups), do: leaf(node, groups)
  defp entry(%{data: {:group, nodes}}, groups), do: Enum.reduce(nodes, groups, &entry/2)
  defp entry(%{data: {:list, nodes}}, groups), do: Enum.reduce(nodes, groups, &entry/2)
  defp entry(%{data: {:set, nodes}}, groups), do: Enum.reduce(nodes, groups, &entry/2)

  defp entry(%{data: {:map, pairs}}, groups),
    do: Enum.reduce(pairs, groups, fn %{key: key, value: value}, acc -> entry(value, entry(key, acc)) end)

  defp entry(%{data: {:change, old, new}}, groups), do: entry(new, entry(old, groups))

  # Уничтоженное ПДн-значение ссылкой не выходит: id в нём не осталось.
  defp leaf(%{value: %Destroyed{}}, groups), do: groups

  defp leaf(%{spec: {:prim, module}, value: %_{} = value}, groups), do: prim(module, value, groups)

  # Значение свободной map'ы: вида у него нет, вид — по самому значению.
  defp leaf(%{spec: nil, value: %module{} = value}, groups) do
    if Core.Prim.prim?(module), do: prim(module, value, groups), else: groups
  end

  defp leaf(_node, groups), do: groups

  defp prim(module, value, groups) do
    case Kind.of(module) do
      {:declared, _owner, %{resolver: nil}} -> groups
      {:declared, owner, %{resolver: resolver}} -> group(groups, resolver, Kind.owned(value, owner))
      _other -> groups
    end
  end

  defp group(groups, resolver, id), do: Map.update(groups, resolver, MapSet.new([id]), &MapSet.put(&1, id))
end
