defmodule Core.Es.Personal.Wire do
  @moduledoc false

  # ПДн-значение в wire-форме события (ADR-0073): маркеры дампа → `{"$pd": base64}` на записи,
  # `{"$pd": …}` → wire-значение места на чтении. Обход рекурсивный: маркер стоит на любом
  # ПДн-месте нагрузки, путь — от корня `payload` (wire-ключи, индексы `list:`, ключи `map:`).
  # Адрес AAD — `event_id` и этот путь. Один вызов порта на пачку строк на запись и на чтение.

  alias Core.Es
  alias Core.Es.Personal.KeyStore
  alias Core.Es.Personal.Marker
  alias Core.Es.Personal.Port
  alias Core.Outbox
  alias Core.Result

  @type path :: [String.t()]

  @typedoc """
  Исход расшифровки конверта: конверт и признак расшифрованного `$pd`, нечитаемое значение места
  (`event_id` и путь) или пропуск.
  """
  @type opened :: {:ok, {map(), boolean()}} | {:unreadable, String.t(), String.t()} | :skip

  # ===== запись =====

  @doc false
  @spec seal_payloads([{String.t(), map() | nil}]) :: Result.t([map() | nil])

  def seal_payloads(entries) when is_list(entries) do
    {payloads, items} =
      Enum.map_reduce(entries, [], fn {event_id, payload}, acc ->
        {payload, items} = collect(payload, event_id, [], [])
        {payload, acc ++ Enum.reverse(items)}
      end)

    case items do
      [] -> {:ok, payloads}
      items -> with {:ok, sealed} <- Port.seal(items), do: {:ok, put_sealed(payloads, sealed)}
    end
  end

  @doc false
  @spec seal_records([Outbox.Record.t()]) :: Result.t([Outbox.Record.t()])

  def seal_records(records) when is_list(records) do
    entries = Enum.map(records, &{event_id(&1.payload), Map.fetch!(&1.payload, "payload")})

    with {:ok, payloads} <- seal_payloads(entries) do
      {:ok, Enum.zip_with(records, payloads, &%{&1 | payload: Map.put(&1.payload, "payload", &2)})}
    end
  end

  # ---

  defp collect(value, event_id, path, items) do
    case value do
      %Marker{} = marker ->
        {value, [item!(event_id, path, marker) | items]}

      %_{} ->
        {value, items}

      value when is_map(value) ->
        Enum.reduce(value, {value, items}, fn {key, inner}, {payload, items} ->
          {inner, items} = collect(inner, event_id, path ++ [step(key)], items)
          {Map.put(payload, key, inner), items}
        end)

      value when is_list(value) ->
        value
        |> Enum.with_index()
        |> Enum.map_reduce(items, fn {inner, index}, items ->
          {inner, items} = collect(inner, event_id, path ++ [Integer.to_string(index)], items)
          {inner, items}
        end)

      _value ->
        {value, items}
    end
  end

  defp item!(event_id, path, %Marker{destroyed: true}) do
    raise ArgumentError,
          "Es.Personal: уничтоженное ПДн-значение не записывается в новое событие: " <>
            "event_id=#{event_id} field=#{label(path)}"
  end

  defp item!(event_id, path, %Marker{subject: subject, value: value}),
    do: {subject, address(event_id, path), Jason.encode!(value)}

  defp put_sealed(payloads, sealed) do
    {payloads, []} =
      Enum.map_reduce(payloads, sealed, fn payload, sealed ->
        traverse(payload, [], sealed, fn _marker, _path, [ciphertext | rest] ->
          {%{"$pd" => Base.encode64(ciphertext)}, rest}
        end)
      end)

    payloads
  end

  # Рекурсивный обход wire-значения: у маркера порядок обхода общий с `collect/4` — шифротексты
  # подставляются в том же порядке, в каком собраны.
  defp traverse(%Marker{} = marker, path, acc, fun), do: fun.(marker, path, acc)
  defp traverse(%_{} = struct, _path, acc, _fun), do: {struct, acc}

  defp traverse(value, path, acc, fun) when is_map(value) do
    Enum.reduce(value, {value, acc}, fn {key, inner}, {payload, acc} ->
      {inner, acc} = traverse(inner, path ++ [step(key)], acc, fun)
      {Map.put(payload, key, inner), acc}
    end)
  end

  defp traverse(value, path, acc, fun) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map_reduce(acc, fn {inner, index}, acc ->
      {inner, acc} = traverse(inner, path ++ [Integer.to_string(index)], acc, fun)
      {inner, acc}
    end)
  end

  defp traverse(value, _path, acc, _fun), do: {value, acc}

  # ===== чтение =====

  # Конверты и шифротексты `extra` (`{шифротекст, адрес}`, снапшоты) — одним вызовом `open`:
  # исходы конвертов и исходы `extra` в их порядке.
  @doc false
  @spec open_wires([map() | :skip], [{binary(), binary()}]) :: Result.t({[opened()], [KeyStore.opened()]})

  def open_wires(wires, extra) when is_list(wires) and is_list(extra) do
    indexed = Enum.with_index(wires)

    items =
      for {wire, index} when is_map(wire) <- indexed,
          {path, sealed} <- places(Map.get(wire, "payload")),
          do: {index, event_id(wire), path, sealed}

    with {:ok, {outcomes, opened_extra}} <- open_items(items, extra) do
      by_index = Enum.group_by(outcomes, &elem(&1, 0), &Tuple.delete_at(&1, 0))
      {:ok, {Enum.map(indexed, fn {wire, index} -> opened(wire, Map.get(by_index, index, [])) end), opened_extra}}
    end
  end

  # ---

  defp places(%{"$pd" => sealed} = value) when map_size(value) == 1 and is_binary(sealed), do: [{[], sealed}]

  defp places(%_{} = _struct), do: []

  defp places(value) when is_map(value) do
    for {key, inner} <- value,
        {path, sealed} <- places(inner),
        do: {[step(key) | path], sealed}
  end

  defp places(value) when is_list(value) do
    for {inner, index} <- Enum.with_index(value),
        {path, sealed} <- places(inner),
        do: {[Integer.to_string(index) | path], sealed}
  end

  defp places(_value), do: []

  # Шифротекст, который не декодируется base64, хранилище не прочтёт: он нечитаем без вызова порта.
  defp open_items(items, extra) do
    decoded = Enum.map(items, fn {index, event_id, path, sealed} -> {index, event_id, path, Base.decode64(sealed)} end)
    port_items = for {_index, event_id, path, {:ok, ciphertext}} <- decoded, do: {ciphertext, address(event_id, path)}

    with {:ok, opened} <- open_port(port_items ++ extra) do
      {opened, opened_extra} = Enum.split(opened, length(port_items))
      {outcomes, []} = Enum.map_reduce(decoded, opened, &outcome/2)
      {:ok, {outcomes, opened_extra}}
    end
  end

  defp open_port([]), do: {:ok, []}
  defp open_port(items), do: Port.open(items)

  defp outcome({index, _event_id, path, :error}, opened), do: {{index, path, :unreadable}, opened}
  defp outcome({index, _event_id, path, {:ok, _ciphertext}}, [outcome | opened]), do: {{index, path, outcome}, opened}

  defp opened(:skip, []), do: :skip

  defp opened(wire, outcomes) do
    case put_opened(Map.get(wire, "payload"), outcomes, event_id(wire), false) do
      {:unreadable, event_id, path} -> {:unreadable, event_id, path}
      {:ok, payload, opened?} -> {:ok, {Map.put(wire, "payload", payload), opened?}}
    end
  end

  defp put_opened(payload, outcomes, event_id, opened?) do
    Enum.reduce_while(outcomes, {:ok, payload, opened?}, fn {path, outcome}, {:ok, payload, opened?} ->
      case opened_value(outcome) do
        {:destroyed, value} ->
          {:cont, {:ok, put_at(payload, path, value), opened?}}

        {:ok, value} ->
          {:cont, {:ok, put_at(payload, path, value), true}}

        :unreadable ->
          {:halt, {:unreadable, event_id, label(path)}}
      end
    end)
  end

  defp opened_value(:destroyed), do: {:destroyed, %{"$pd" => nil}}
  defp opened_value(:unreadable), do: :unreadable

  defp opened_value({:ok, plaintext}) do
    case Jason.decode(plaintext) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :unreadable
    end
  end

  defp put_at(_payload, [], value), do: value

  defp put_at(payload, [key | rest], value) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, inner} -> Map.put(payload, key, put_at(inner, rest, value))
      :error -> payload
    end
  end

  defp put_at(payload, [index | rest], value) when is_list(payload),
    do: List.update_at(payload, String.to_integer(index), &put_at(&1, rest, value))

  # ===== общее =====

  defp label([]), do: "payload"
  defp label(path), do: Enum.join(path, ".")

  defp step(key) when is_binary(key), do: key
  defp step(key), do: to_string(key)

  defp event_id(envelope), do: Es.Event.Codec.to_fields(envelope).id

  defp address(event_id, path), do: Port.address([event_id | path])
end
