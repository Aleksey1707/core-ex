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
  находит его у автора события и на любой глубине нагрузки: в struct'ах, ключах и значениях map'ы,
  списках, нагрузке-семействе, Prim-композите. Остальные поля события (`aggregate_id`, `id`) в
  сведения не выходят и не обходятся. В `Date`, `DateTime`, `NaiveDateTime`, `Time`, `Decimal`, Prim без
  вида id, id `kind: :id` и Prim с `Core.Labels.Text` он не спускается: id там нет или он не выходит
  ссылкой. Вид модуля проверяется один раз на модуль в пределах вызова.

  Скрытые поля не обходятся: у struct'а с `use Core.Labels.Fields` обход идёт по тем же полям, что и
  сведения (`Core.Labels.Details`), — по видимым (`Core.Labels.Fields.specs/1`), у варианта семейства по
  его полям, у struct'а изменения по `old_value` / `new_value`. Id в поле `:hidden` в сведения не
  выходит, и резолвер его не получает. Struct без объявления полей обходится целиком.

  Значение `text:` не обходится: поле `text:` и `list: [text: …]`, у struct'а изменения со спекой значения
  `value: [text: …]` / `[list: [text: …]]` — ни `old_value`, ни `new_value`. Оно выходит в сведения
  текстом функции, и id в нём ссылкой не выходит. Словарь не шире сведений: каждый его id, кроме
  автора события, есть в сведениях.

  Id группируются по резолверу, и резолвер (`Core.Labels.Resolver`) вызывается один раз на группу
  пачкой уникальных id. Без id с резолвером — `{:ok, %{}}` без вызовов. Отказ резолвера — итог; у
  записи без имени — `nil`.
  """

  alias Core.Context
  alias Core.Es
  alias Core.Labels.Fields
  alias Core.Labels.Kind
  alias Core.Pagination
  alias Core.Result

  @typedoc "Словарь ссылок: имя по id, у записи без имени — `nil`."
  @type t :: %{struct() => String.t() | nil}

  # Struct'ы значений, внутри которых id нет.
  @leaves [Date, DateTime, NaiveDateTime, Time, Decimal]

  @doc "Словарь ссылок страницы событий, списка событий или события."
  @spec get(Pagination.Result.t(Es.Event.t()) | [Es.Event.t()] | Es.Event.t(), Context.t()) :: Result.t(t())

  def get(%Pagination.Result{items: events}, %Context{} = context), do: get(events, context)

  def get(events, %Context{} = context) when is_list(events) do
    {groups, _roles} =
      Enum.reduce(events, {%{}, %{}}, fn %_{payload: payload, by: by}, acc -> collect([payload, by], acc) end)

    groups
    |> Map.to_list()
    |> Result.traverse(fn {resolver, ids} -> resolver.get_names(MapSet.to_list(ids), context) end)
    |> Result.map(&Enum.reduce(&1, %{}, fn names, refs -> Map.merge(refs, names) end))
  end

  def get(%_{payload: _, by: _} = event, %Context{} = context), do: get([event], context)

  # ---

  defp collect(%module{} = struct, acc) do
    case role(module, acc) do
      {:skip, acc} ->
        acc

      {:descend, acc} ->
        collect(Map.values(Map.from_struct(struct)), acc)

      {{:fields, names}, acc} ->
        collect(Map.values(Map.take(struct, names)), acc)

      {{:id, owner, resolver}, {groups, roles}} ->
        id = Kind.owned(struct, owner)

        {Map.update(groups, resolver, MapSet.new([id]), &MapSet.put(&1, id)), roles}
    end
  end

  defp collect(map, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {key, value}, acc -> collect(value, collect(key, acc)) end)

  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_term, acc), do: acc

  defp role(module, {groups, roles} = acc) do
    case roles do
      %{^module => role} ->
        {role, acc}

      %{} ->
        role = classify(module)
        {role, {groups, Map.put(roles, module, role)}}
    end
  end

  defp classify(module) when module in @leaves, do: :skip

  defp classify(module) do
    cond do
      Core.Prim.prim?(module) -> prim_role(module)
      Fields.labelled?(module) -> {:fields, visible_fields(module)}
      true -> :descend
    end
  end

  # Композит без своего объявления выходит объявлением базы: ссылка — id владельца объявления.
  defp prim_role(module) do
    case Kind.of(module) do
      {:declared, _owner, %{resolver: nil}} -> :skip
      {:declared, owner, %{resolver: resolver}} -> {:id, owner, resolver}
      _other -> :skip
    end
  end

  defp visible_fields(module), do: for({name, spec} <- Fields.visible(module), not text?(spec), do: name)

  # Значение `text:` выходит в сведения текстом функции, а не ссылкой.
  defp text?({:text, _fun}), do: true
  defp text?({:list, inner}), do: text?(inner)
  defp text?(_spec), do: false
end
