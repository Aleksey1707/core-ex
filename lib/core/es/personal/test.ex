defmodule Core.Es.Personal.Test do
  @moduledoc """
  Тестовая поддержка ПДн в событиях без БД и без хранилища ключей (ADR-0074, ADR-0078).

  - `destroyed/2` — нагрузка или событие с `%Core.Es.Personal.Destroyed{}` на каждом ПДн-месте
    плана (`__es_personal__/0`): вход `evolve/2` через `fold/2`, `given` и прямого `project/1`.
    `new/N` нагрузки уничтоженное значение не принимает, а литерал `%Payload{}` поставил бы его и
    вне ПДн-места, чего в хранилище не бывает.
  - `fixtures/1` — тела golden-фикстур события: открытой `<тег>.json` и уничтоженного варианта
    `destroyed/<тег>.json`. Обе формы строятся по ПДн-плану: открытая — открытые wire-значения
    мест, уничтоженная — `{"$pd": null}` на каждом месте (в том числе вложенном). Файлы пишет
    автор.
  - `key_destroyed/2` — событие уничтожения ключа субъекта (ADR-0079): вход прямого `project/1`
    проекции, которая его объявила.

      event = Core.Es.Personal.Test.destroyed(holder_set)
      assert %Account{holder: %Destroyed{}} = Account.fold(state, [event])
  """

  import Core.Guard, only: [is_prim: 1]

  alias Core.Config
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.Personal.Marker
  alias Core.Es.Personal.Plan
  alias Core.Exc

  use Core.Options

  @typedoc "Тела golden-фикстур события; `destroyed` — `nil` у события без полей с `subject:`."
  @type fixtures :: %{open: map(), destroyed: map() | nil}

  # ===== уничтоженное значение =====

  @doc """
  Нагрузка (`new/N`) или событие с нагрузкой по полям → то же с `%Destroyed{}` на каждом ПДн-месте
  плана: во всех (`:all`) или в местах перечисленных полей верхнего уровня.

  `nil` необязательного места остаётся `nil`: незаполненное значение не шифруется, и уничтожение
  ключа его не меняет. Поле без ПДн-места или нагрузка без мест — `ArgumentError`.
  """
  @spec destroyed(struct(), :all | [atom()]) :: struct()

  def destroyed(%mod{} = value, fields \\ :all) when fields == :all or is_list(fields) do
    if Core.Helper.Module.exports?(mod, :__es_payload__, 0),
      do: %{value | payload: destroy(value.payload, fields)},
      else: destroy(value, fields)
  end

  # ---

  defp destroy(nil, _fields), do: raise(ArgumentError, "nil: нет полей с subject:")

  defp destroy(%mod{} = payload, fields) do
    entries = names!(Plan.runtime_places(mod), mod, fields)

    Enum.reduce(entries, payload, &destroy_at(&2, &1.path))
  end

  defp names!(entries, mod, fields), do: names!(entries, roots(entries), mod, fields)

  defp names!([], _roots, mod, _fields), do: raise(ArgumentError, "#{inspect(mod)}: нет полей с subject:")
  defp names!(entries, _roots, _mod, :all), do: entries

  defp names!(entries, roots, mod, fields) do
    case fields -- roots do
      [] -> Enum.filter(entries, &(root(&1) in fields))
      other -> raise ArgumentError, "#{inspect(mod)}: поля #{inspect(other)} без subject:"
    end
  end

  defp roots(entries), do: Enum.uniq(Enum.map(entries, &root/1))
  defp root(%{path: []}), do: :payload
  defp root(%{path: [step | _rest]}), do: step

  defp destroy_at(value, []), do: if(is_nil(value), do: nil, else: %Destroyed{})

  defp destroy_at(list, [:each | rest]) when is_list(list),
    do: Enum.map(list, &destroy_at(&1, rest))

  defp destroy_at(map, [:each | rest]) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, destroy_at(value, rest)} end)

  defp destroy_at(%_{} = struct, [step | rest]) when is_atom(step),
    do: Map.put(struct, step, destroy_at(Map.fetch!(struct, step), rest))

  defp destroy_at(map, [step | rest]) when is_map(map) and is_atom(step),
    do: Map.put(map, step, destroy_at(Map.fetch!(map, step), rest))

  defp destroy_at(value, _path), do: value

  # ===== тела фикстур =====

  @doc """
  Тела golden-фикстур события (ADR-0078): дамп фасадом `Core.Config.codec/0` в форме JSON-файла.

  - `open` — конверт после расшифровки: на месте ПДн-значения его открытое wire-значение;
  - `destroyed` — тот же конверт с `{"$pd": null}` на каждом ПДн-месте плана (`__es_personal__/0`),
    в том числе вложенном; `nil` у события без ПДн-мест. `null` необязательного места остаётся
    `null`, и такой вариант `Core.Es.EventCompatCase` не примет: места в фикстуре заполняются.
  """
  @spec fixtures(Es.Event.t()) :: fixtures()

  def fixtures(%mod{} = event) do
    wire = Config.codec().dump(event)

    destroyed = if plan(mod) != [], do: through_json(walk(wire, &destroyed_value/1))

    %{open: through_json(walk(wire, &open_value/1)), destroyed: destroyed}
  end

  # ---

  defp plan(mod) when is_atom(mod) do
    if Core.Helper.Module.exports?(mod, :__es_family__, 0),
      do: Map.get(mod.__es_family__().__es_codec__().__es_personal__(), mod, []),
      else: []
  end

  # Маркер — на любом ПДн-месте нагрузки: значения и элементы списков обходятся рекурсивно.
  defp walk(%Marker{} = marker, fun), do: fun.(marker)
  defp walk(%_{} = value, _fun), do: value
  defp walk(map, fun) when is_map(map), do: Map.new(map, fn {key, value} -> {key, walk(value, fun)} end)
  defp walk(list, fun) when is_list(list), do: Enum.map(list, &walk(&1, fun))
  defp walk(value, _fun), do: value

  # Тело — то, что прочтёт `Jason.decode` из файла: строковые ключи, даты строкой.
  defp through_json(wire), do: Jason.decode!(Jason.encode!(wire))

  defp open_value(%Marker{destroyed: true}), do: %{"$pd" => nil}
  defp open_value(%Marker{value: value}), do: value
  defp open_value(value), do: value

  defp destroyed_value(%Marker{}), do: %{"$pd" => nil}
  defp destroyed_value(value), do: value

  # ===== событие уничтожения ключа =====

  @opts_schema [
    by: [type: :any, required: true, doc: "Автор уничтожения — UUID-Prim, как `subject_id`."],
    at: [type: {:struct, Es.Event.At}, required: true, doc: "Время события."]
  ]
  @doc """
  Событие уничтожения ключа субъекта `subject_id` — в той форме, в какой его пишет
  `Core.Es.Personal.destroy_key/3`: поток `"core.subject"`, версия `1`, без нагрузки, `id` — новый.

  `subject_id` — UUID-Prim (`Prim.UUID` или `Prim.Compose` над ним).

  ## Опции

  #{Core.Options.docs(@opts_schema)}
  """
  @spec key_destroyed(struct(), keyword()) :: KeyDestroyed.t()

  def key_destroyed(subject_id, opts) when is_prim(subject_id) and is_list(opts) do
    case Personal.key_destroyed(subject_id, Keyword.fetch!(opts, :by), Keyword.fetch!(opts, :at)) do
      {:ok, %KeyDestroyed{} = event} -> event
      {:error, %Error{} = error} -> raise Exc, error
    end
  end
end
