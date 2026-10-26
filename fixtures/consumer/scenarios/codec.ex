defmodule ConsumerTest.Codec do
  @moduledoc "Кодек событий напрямую и фасад Codec."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Codec.Internal, as: InCodec

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

  # H7 — опечатка в поле результата `load/2` плагина по полям
  def h7_fields_load_typo(data) do
    {:ok, profile} = InCodec.load(Account.Profile, data)
    # expect: unknown key .nmae
    profile.nmae
  end

  # H8 — поле не того Prim в `dump/2` плагина по полям; через `InCodec.dump/1` поля struct до головы
  # плагина не доходят, и там то же значение — `FunctionClauseError` при исполнении
  def h8_fields_dump_wrong_prim(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Domain.Sales.Account.Profile.Codec.dump/2
    do: Account.Profile.Codec.dump(%Account.Profile{id: name, name: name, status: :placed, contacts: []}, InCodec)

  # H8s — список вместо множества (`set:`) в `dump/2` плагина по полям
  def h8s_fields_dump_set_list(%Account.ID{} = id, %Account.Name{} = name) do
    profile = %Account.Profile{id: id, name: name, status: :placed, contacts: [], aliases: [name]}
    # expect: incompatible types given to Consumer.Domain.Sales.Account.Profile.Codec.dump/2
    Account.Profile.Codec.dump(profile, InCodec)
  end

  # H8m — список вместо словаря (`map:`) в `dump/2` плагина по полям
  def h8m_fields_dump_map_list(%Account.ID{} = id, %Account.Name{} = name) do
    profile = %Account.Profile{id: id, name: name, status: :placed, contacts: [], escalation: []}
    # expect: incompatible types given to Consumer.Domain.Sales.Account.Profile.Codec.dump/2
    Account.Profile.Codec.dump(profile, InCodec)
  end

  # H9a — опечатка в поле результата `load/2` варианта семейства
  def h9a_variant_load_typo(data) do
    {:ok, mobile} = InCodec.load(Account.Profile.Channel.Mobile, data)
    # expect: unknown key .numbr
    mobile.numbr
  end

  # H9b — `:ok` по результату `load/2` семейства вариантов
  def h9b_family_load_ok(data) do
    case InCodec.load(Account.Profile.Channel, data) do
      {:ok, channel} -> channel
      # expect: the following clause will never match
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # H9c — поле не того Prim в `dump/2` варианта
  def h9c_variant_dump_wrong_prim(%Account.ID{} = id),
    # expect: incompatible types given to Consumer.Domain.Sales.Account.Profile.Channel.Codec.dump/2
    do: Account.Profile.Channel.Codec.dump(%Account.Profile.Channel.Email{address: id}, InCodec)

  # H6 — команда в `dump/1` фасада: не Prim и не тип плагина
  def h6_dump_command(%Account.Cmd.Open{} = command),
    # expect: incompatible types given to Consumer.Codec.Internal.dump/1
    do: InCodec.dump(command)
end
