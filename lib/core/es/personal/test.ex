defmodule Core.Es.Personal.Test do
  @moduledoc """
  Тестовая поддержка ПДн в событиях без БД и без хранилища ключей (ADR-0074, ADR-0078).

  - `destroyed/2` — нагрузка или событие с `%Core.Es.Personal.Destroyed{}` в полях с `subject:`:
    вход `evolve/2` через `fold/2`, `given` и прямого `project/1`. `new/N` нагрузки уничтоженное
    значение не принимает, а литерал `%Payload{}` поставил бы его и в поле без `subject:`, чего
    в хранилище не бывает.
  - `fixtures/1` — тела golden-фикстур события: открытой `<тег>.json` и уничтоженного варианта
    `destroyed/<тег>.json`. Файлы пишет автор.
  - `key_destroyed/2` — событие уничтожения ключа субъекта (ADR-0079): вход прямого `project/1`
    проекции, которая его объявила.

      event = Core.Es.Personal.Test.destroyed(holder_set)
      assert %Account{holder: %Destroyed{}} = Account.fold(state, [event])
  """

  import Core.Guard, only: [is_prim: 1]

  alias Core.Codec.Field
  alias Core.Config
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.Personal.Marker
  alias Core.Exc

  use Core.Options

  @typedoc "Тела golden-фикстур события; `destroyed` — `nil` у события без полей с `subject:`."
  @type fixtures :: %{open: map(), destroyed: map() | nil}

  # ===== уничтоженное значение =====

  @doc """
  Нагрузка (`new/N`) или событие с нагрузкой по полям → то же с `%Destroyed{}` в полях с
  `subject:`: во всех (`:all`) или в перечисленных.

  `nil` необязательного поля остаётся `nil`: незаполненное значение не шифруется, и уничтожение
  ключа его не меняет. Поле без `subject:` или нагрузка без таких полей — `ArgumentError`.
  """
  @spec destroyed(struct(), :all | [atom()]) :: struct()

  def destroyed(%mod{} = value, fields \\ :all) when fields == :all or is_list(fields) do
    if Core.Helper.Module.exports?(mod, :__es_payload__, 0),
      do: %{value | payload: destroy(value.payload, fields)},
      else: destroy(value, fields)
  end

  # ---

  defp destroy(%mod{} = payload, fields) do
    mod
    |> names!(subject_fields(mod), fields)
    |> Enum.reject(&is_nil(Map.fetch!(payload, &1)))
    |> Enum.reduce(payload, &Map.put(&2, &1, %Destroyed{}))
  end

  defp names!(mod, [], _fields), do: raise(ArgumentError, "#{inspect(mod)}: нет полей с subject:")
  defp names!(_mod, subjects, :all), do: subjects

  defp names!(mod, subjects, fields) do
    case fields -- subjects do
      [] -> fields
      other -> raise ArgumentError, "#{inspect(mod)}: поля #{inspect(other)} без subject:"
    end
  end

  # ===== тела фикстур =====

  @doc """
  Тела golden-фикстур события (ADR-0078): дамп фасадом `Core.Config.codec/0` в форме JSON-файла.

  - `open` — конверт после расшифровки: на месте ПДн-значения его открытое wire-значение;
  - `destroyed` — тот же конверт с `{"$pd": null}` на месте каждого ПДн-значения; `nil` у события
    без полей с `subject:`. `null` необязательного поля остаётся `null`, и такой вариант
    `Core.Es.EventCompatCase` не примет: поля с `subject:` в фикстуре заполняются.
  """
  @spec fixtures(Es.Event.t()) :: fixtures()

  def fixtures(%mod{} = event) do
    wire = Config.codec().dump(event)

    destroyed =
      if subject_fields(mod.__es_payload__()) != [],
        do: body(wire, &destroyed_value/1)

    %{open: body(wire, &open_value/1), destroyed: destroyed}
  end

  # ---

  defp body(%{"payload" => %{} = payload} = wire, fun),
    do: through_json(%{wire | "payload" => Map.new(payload, fn {key, value} -> {key, fun.(value)} end)})

  defp body(wire, _fun), do: through_json(wire)

  # Тело — то, что прочтёт `Jason.decode` из файла: строковые ключи, даты строкой.
  defp through_json(wire), do: Jason.decode!(Jason.encode!(wire))

  defp open_value(%Marker{destroyed: true}), do: %{"$pd" => nil}
  defp open_value(%Marker{value: value}), do: value
  defp open_value(value), do: value

  defp destroyed_value(%Marker{}), do: %{"$pd" => nil}
  defp destroyed_value(value), do: value

  # ===== событие уничтожения ключа =====

  @doc """
  Событие уничтожения ключа субъекта `subject_id` — в той форме, в какой его пишет
  `Core.Es.Personal.destroy_key/3`: поток `"core.subject"`, версия `1`, без нагрузки, `id` — новый.

  `subject_id` — UUID-Prim (`Prim.UUID` или `Prim.Compose` над ним).
  """
  @opts_schema [
    by: [type: :any, required: true, doc: "Автор уничтожения — UUID-Prim, как `subject_id`."],
    at: [type: {:struct, Es.Event.At}, required: true, doc: "Время события."]
  ]
  @spec key_destroyed(struct(), keyword()) :: KeyDestroyed.t()

  def key_destroyed(subject_id, opts) when is_prim(subject_id) and is_list(opts) do
    case Personal.key_destroyed(subject_id, Keyword.fetch!(opts, :by), Keyword.fetch!(opts, :at)) do
      {:ok, %KeyDestroyed{} = event} -> event
      {:error, %Error{} = error} -> raise Exc, error
    end
  end

  # ===== общее =====

  defp subject_fields(payload) do
    if Core.Helper.Module.exports?(payload, :__es_payload_fields__, 0),
      do: Keyword.keys(Field.subjects(payload.__es_payload_fields__())),
      else: []
  end
end
