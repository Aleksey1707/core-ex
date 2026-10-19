defmodule Core.Es.Personal.Wire do
  @moduledoc false

  # ПДн-значение в wire-форме события (ADR-0073): маркеры дампа → `{"$pd": base64}` на записи,
  # `{"$pd": …}` → wire-значение поля на чтении. Значения ищутся среди полей нагрузки верхнего
  # уровня: только там стоит поле с `subject:`. Адрес AAD — `event_id` и wire-ключ поля.

  alias Core.Es
  alias Core.Es.Personal.KeyStore
  alias Core.Es.Personal.Marker
  alias Core.Es.Personal.Port
  alias Core.Outbox
  alias Core.Result

  @typedoc """
  Исход расшифровки конверта: конверт и признак расшифрованного `$pd`, нечитаемое значение поля
  (`event_id` и wire-ключ) или пропуск.
  """
  @type opened :: {:ok, {map(), boolean()}} | {:unreadable, String.t(), String.t()} | :skip

  # ===== запись =====

  @doc false
  @spec seal_payloads([{String.t(), map() | nil}]) :: Result.t([map() | nil])

  def seal_payloads(entries) when is_list(entries) do
    items =
      for {event_id, payload} <- entries,
          {key, %Marker{} = marker} <- fields(payload),
          do: item!(event_id, key, marker)

    case items do
      [] -> {:ok, Enum.map(entries, &elem(&1, 1))}
      items -> with {:ok, sealed} <- Port.seal(items), do: {:ok, put_sealed(entries, sealed)}
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

  defp item!(event_id, key, %Marker{destroyed: true}) do
    raise ArgumentError,
          "Es.Personal: уничтоженное ПДн-значение не записывается в новое событие: " <>
            "event_id=#{event_id} field=#{key}"
  end

  defp item!(event_id, key, %Marker{subject: subject, value: value}),
    do: {subject, address(event_id, key), Jason.encode!(value)}

  defp put_sealed(entries, sealed) do
    {payloads, []} =
      Enum.map_reduce(entries, sealed, fn {_event_id, payload}, sealed -> replace_markers(payload, sealed) end)

    payloads
  end

  defp replace_markers(payload, sealed) when is_map(payload) do
    Enum.reduce(payload, {payload, sealed}, fn
      {key, %Marker{}}, {payload, [ciphertext | sealed]} ->
        {Map.put(payload, key, %{"$pd" => Base.encode64(ciphertext)}), sealed}

      _field, acc ->
        acc
    end)
  end

  defp replace_markers(payload, sealed), do: {payload, sealed}

  # ===== чтение =====

  # Конверты и шифротексты `extra` (`{шифротекст, адрес}`, снапшоты) — одним вызовом `open`:
  # исходы конвертов и исходы `extra` в их порядке.
  @doc false
  @spec open_wires([map() | :skip], [{binary(), binary()}]) :: Result.t({[opened()], [KeyStore.opened()]})

  def open_wires(wires, extra) when is_list(wires) and is_list(extra) do
    indexed = Enum.with_index(wires)

    items =
      for {wire, index} when is_map(wire) <- indexed,
          {key, sealed} <- sealed_fields(wire),
          do: {index, event_id(wire), key, sealed}

    with {:ok, {outcomes, opened_extra}} <- open_items(items, extra) do
      by_index = Enum.group_by(outcomes, &elem(&1, 0), &Tuple.delete_at(&1, 0))
      {:ok, {Enum.map(indexed, fn {wire, index} -> opened(wire, Map.get(by_index, index, [])) end), opened_extra}}
    end
  end

  # ---

  # Шифротекст, который не декодируется base64, хранилище не прочтёт: он нечитаем без вызова порта.
  defp open_items(items, extra) do
    decoded = Enum.map(items, fn {index, event_id, key, sealed} -> {index, event_id, key, Base.decode64(sealed)} end)
    port_items = for {_index, event_id, key, {:ok, ciphertext}} <- decoded, do: {ciphertext, address(event_id, key)}

    with {:ok, opened} <- open_port(port_items ++ extra) do
      {opened, opened_extra} = Enum.split(opened, length(port_items))
      {outcomes, []} = Enum.map_reduce(decoded, opened, &outcome/2)
      {:ok, {outcomes, opened_extra}}
    end
  end

  defp open_port([]), do: {:ok, []}
  defp open_port(items), do: Port.open(items)

  defp outcome({index, event_id, key, :error}, opened), do: {{index, event_id, key, :unreadable}, opened}

  defp outcome({index, event_id, key, {:ok, _ciphertext}}, [outcome | opened]),
    do: {{index, event_id, key, outcome}, opened}

  defp opened(:skip, []), do: :skip
  defp opened(wire, []), do: {:ok, {wire, false}}

  defp opened(wire, outcomes) do
    case Enum.reduce_while(outcomes, Map.fetch!(wire, "payload"), &put_opened/2) do
      {:unreadable, _event_id, _key} = unreadable -> unreadable
      payload -> {:ok, {Map.put(wire, "payload", payload), Enum.any?(outcomes, &match?({_, _, {:ok, _}}, &1))}}
    end
  end

  defp put_opened({_event_id, key, :destroyed}, payload), do: {:cont, Map.put(payload, key, %{"$pd" => nil})}

  defp put_opened({event_id, key, {:ok, plaintext}}, payload) do
    case Jason.decode(plaintext) do
      {:ok, value} -> {:cont, Map.put(payload, key, value)}
      {:error, _reason} -> {:halt, {:unreadable, event_id, key}}
    end
  end

  defp put_opened({event_id, key, :unreadable}, _payload), do: {:halt, {:unreadable, event_id, key}}

  defp sealed_fields(wire) do
    for {key, %{"$pd" => sealed} = value} <- fields(Map.get(wire, "payload")),
        map_size(value) == 1 and is_binary(sealed),
        do: {key, sealed}
  end

  # ===== общее =====

  defp fields(payload) when is_map(payload), do: payload
  defp fields(_payload), do: []

  defp event_id(envelope), do: Es.Event.Codec.to_fields(envelope).id

  defp address(event_id, key), do: Port.address([event_id, key])
end
