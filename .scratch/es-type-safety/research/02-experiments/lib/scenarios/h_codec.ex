defmodule Blind.S.Codec do
  alias Blind.Account
  alias Blind.Codec.Internal, as: InCodec
  alias Blind.Parcel

  # H3a — load по семейству и опечатка в поле события
  def h3a_family_typo(data) do
    {:ok, event} = InCodec.load(Account.Event, data)
    event.aggregat_id
  end

  # H3b — load по модулю события и опечатка в поле нагрузки
  def h3b_mod_payload_typo(data) do
    {:ok, event} = InCodec.load(Account.Event.Opened, data)
    event.payload.nmae
  end

  # H3c — невозможная clause по результату load
  def h3c_case_load(data) do
    case InCodec.load(Account.Event, data) do
      :ok -> nil
      {:ok, event} -> event
      {:error, _error} -> nil
    end
  end

  # H3d — load! и сопоставление с %Opened{}, опечатка
  def h3d_load_bang_matched(data) do
    %Account.Event.Opened{} = event = InCodec.load!(Account.Event.Opened, data)
    event.aggregat_id
  end

  # H1 — dump события без clause dump_payload/2 (через фасад и напрямую)
  def h1_dump_missing(%Parcel.Event.Lost{} = event), do: InCodec.dump(event)

  def h1_direct_dump_payload(%Parcel.Event.Lost{} = event),
    do: Parcel.Event.Codec.dump_payload(event, InCodec)

  def h1_direct_load_payload(wire), do: Parcel.Event.Codec.load_payload(Parcel.Event.Lost, wire, InCodec)

  # H4 — не-struct в dump фасада; модуль без плагина в load
  def h4_dump_not_struct, do: InCodec.dump("not a struct")

  def h4b_load_unknown_module(data), do: InCodec.load(Blind.Order.Cmd.Place, data)

  # H5 — кодек агрегата напрямую: dump/2 чужого события
  def h5_codec_dump_foreign(%Blind.Order.Event.Cancelled{} = event),
    do: Account.Event.Codec.dump(event, InCodec)
end
