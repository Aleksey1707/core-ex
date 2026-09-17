defmodule Consumer.S.BadCodec do
  @moduledoc "Кодек без clause `dump_payload/2` и `load_payload/3` для `Lost`; в фасад не входит."

  alias Consumer.Parcel.Event

  # H1 — нет clause `dump_payload/2` и `load_payload/3` для `Lost`: проверки полноты на строке `use`
  # expect: incompatible types given to dump_payload/2
  # expect: incompatible types given to load_payload/3
  use Core.Es.Event.Codec,
    event: Event,
    type: "bad_codec",
    tags: %{Event.Sent => "bad_codec.sent", Event.Lost => "bad_codec.lost"}

  @impl true
  def dump_payload(%Event.Sent{payload: %Event.Sent.Payload{} = payload}, _codec),
    do: %{"note" => payload.note}

  @impl true
  def load_payload(Event.Sent, wire, _codec) when is_map(wire),
    do: {:ok, %Event.Sent.Payload{note: field(wire, :note)}}
end

defmodule Consumer.S.BadCodecPayload do
  @moduledoc "Кодек, чей `load_payload/3` отдаёт литерал нагрузки другого события; в фасад не входит."

  alias Consumer.Account
  alias Consumer.Parcel.Event

  # H2 — `load_payload/3` для `Sent` отдаёт литерал нагрузки `Account.Event.Renamed`
  # expect: the following clause will never match
  use Core.Es.Event.Codec,
    event: Event,
    type: "bad_codec_payload",
    tags: %{Event.Sent => "bad_codec_payload.sent"}

  @impl true
  def dump_payload(%Event.Sent{payload: %Event.Sent.Payload{} = payload}, _codec),
    do: %{"note" => payload.note}

  @impl true
  def load_payload(Event.Sent, wire, _codec) when is_map(wire),
    do: {:ok, %Account.Event.Renamed.Payload{name: field(wire, :note)}}
end

defmodule Consumer.S.BadCodecPayloadNew do
  @moduledoc "Кодек, чей `load_payload/3` собирает нагрузку другого события конструктором; в фасад не входит."

  alias Consumer.Account
  alias Consumer.Parcel.Event

  # H2n — `load_payload/3` для `Sent` отдаёт нагрузку `Account.Event.Renamed` через `Payload.new/1`
  # expect: the following clause will never match
  use Core.Es.Event.Codec,
    event: Event,
    type: "bad_codec_payload_new",
    tags: %{Event.Sent => "bad_codec_payload_new.sent"}

  @impl true
  def dump_payload(%Event.Sent{payload: %Event.Sent.Payload{} = payload}, _codec),
    do: %{"note" => payload.note}

  @impl true
  def load_payload(Event.Sent, wire, codec) do
    with {:ok, name} <- codec.load(Account.Name, field(wire, :note)) do
      {:ok, Account.Event.Renamed.Payload.new(name)}
    end
  end
end

defmodule Consumer.S.BadCodecSharedPayload do
  @moduledoc "Кодек, чей `load_payload/3` отдаёт чужую нагрузку обоим событиям с общим модулем нагрузки; в фасад не входит."

  alias Consumer.Grants
  alias Consumer.Grants.Event
  alias Consumer.Order

  # H2g — H2 у обоих событий с общим модулем нагрузки: предупреждение на каждое
  # expect: the following clause will never match
  # expect: the following clause will never match
  use Core.Es.Event.Codec,
    event: Event,
    type: "bad_codec_shared_payload",
    tags: %{Event.Granted => "bad_codec_shared_payload.granted", Event.Revoked => "bad_codec_shared_payload.revoked"}

  @impl true
  def dump_payload(%Event.Granted{payload: %Grants.RoleID{} = role}, codec), do: codec.dump(role)
  def dump_payload(%Event.Revoked{payload: %Grants.RoleID{} = role}, codec), do: codec.dump(role)

  @impl true
  def load_payload(Event.Granted, _wire, _codec), do: {:ok, %Order.Amount{value: 1}}
  def load_payload(Event.Revoked, _wire, _codec), do: {:ok, %Order.Amount{value: 1}}
end

defmodule Consumer.S.Codec do
  @moduledoc "Кодек событий напрямую и фасад Codec."

  alias Consumer.Account
  alias Consumer.Codec.Internal, as: InCodec
  alias Consumer.Parcel
  alias Consumer.S.BadCodec

  # H1d — прямой `dump_payload/2` события без clause
  def h1_direct_dump_payload(%Parcel.Event.Lost{} = event),
    # expect: incompatible types given to Consumer.S.BadCodec.dump_payload/2
    do: BadCodec.dump_payload(event, InCodec)

  # H1d — прямой `load_payload/3` события без clause
  def h1_direct_load_payload(wire),
    # expect: incompatible types given to Consumer.S.BadCodec.load_payload/3
    do: BadCodec.load_payload(Parcel.Event.Lost, wire, InCodec)

  # H3a — опечатка в поле события после `load/2` по семейству
  def h3a_family_typo(data) do
    {:ok, event} = InCodec.load(Account.Event, data)
    # expect: unknown key .aggregat_id
    event.aggregat_id
  end

  # H3b — опечатка в поле нагрузки после `load/2` по модулю события
  def h3b_payload_typo(data) do
    {:ok, event} = InCodec.load(Account.Event.Opened, data)
    # expect: unknown key .nmae
    event.payload.nmae
  end

  # H3c — `:ok` по результату `load/2`
  def h3c_case_load_ok(data) do
    case InCodec.load(Account.Event, data) do
      {:ok, event} -> event
      # expect: the following clause will never match
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # H3d — опечатка в поле события, суженного паттерном после `load!/2`
  def h3d_load_bang_matched(data) do
    %Account.Event.Opened{} = event = InCodec.load!(Account.Event.Opened, data)
    # expect: unknown key .aggregat_id
    event.aggregat_id
  end

  # H3e — опечатка в поле события после `load!/2` без паттерна
  def h3e_load_bang_typo(data) do
    event = InCodec.load!(Account.Event, data)
    # expect: unknown key .aggregat_id
    event.aggregat_id
  end

  # H4 — не-struct в `dump/1` фасада
  # expect: incompatible types given to Consumer.Codec.Internal.dump/1
  def h4_dump_not_struct, do: InCodec.dump("not a struct")

  # H6 — команда в `dump/1` фасада: не Prim и не тип плагина
  def h6_dump_command(%Account.Cmd.Open{} = command),
    # expect: incompatible types given to Consumer.Codec.Internal.dump/1
    do: InCodec.dump(command)
end
