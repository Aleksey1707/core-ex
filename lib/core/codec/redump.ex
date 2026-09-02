defmodule Core.Codec.Redump do
  @moduledoc """
  Пере-дамп wire-нагрузки, записанной другим профилем кодека.

  jsonb read-пути (снимки, полиморфные нагрузки шагов) лежит в БД в той форме, в какой
  его записал внутренний профиль, а наружу обязан уйти в форме внешнего: даты в tz
  приложения, uuid и decimal — каждый в своём формате. Разбирать нагрузку в домен ради
  этого нельзя — её форма полиморфна, а read-путь не валидирует. Поэтому значения
  переводятся по спеке формы: какое поле каким Prim задано.

  Спека приходит аргументом: Core не знает доменных кодеков, а объявляет её тот кодек,
  который эту wire-форму пишет.

  Тотальна по значению: отсутствующий ключ, неизвестный тег и значение неподходящего
  типа проходят как есть — страница списка не должна падать из-за одной строки. Спека
  же строга: не описанная здесь форма — ошибка программиста, а не данных.

  Envelope `{:tagged, _}` — map-представление пары `{тег, нагрузка}` (`Facade.dump_tagged/1`):
  ключи `type` и `fields`.
  """

  alias Core.Helper
  alias Core.Prim

  @type spec ::
          {:prim, module()}
          | {:map, %{optional(atom()) => spec()}}
          | {:list, spec()}
          | {:tagged, %{optional(String.t()) => spec()}}

  @tag_key :type
  @payload_key :fields

  # ===== redump =====

  @doc "Перевести wire-значение в формат кодека `codec` по спеке формы."
  @spec run(term(), spec(), module()) :: term()

  def run(nil, _spec, _codec), do: nil

  def run(value, {:prim, mod}, codec) when is_atom(mod), do: codec.dump_raw_as(mod, value)

  def run(value, {:list, spec}, codec) when is_list(value) do
    Enum.map(value, &run(&1, spec, codec))
  end

  def run(value, {:list, _spec}, _codec), do: value

  def run(value, {:tagged, by_tag}, codec) when is_map(value) and is_map(by_tag) do
    run_tagged(value, by_tag, codec)
  end

  def run(value, {:tagged, by_tag}, _codec) when is_map(by_tag), do: value

  def run(value, {:map, fields}, codec) when is_map(value) and is_map(fields) do
    run_fields(value, fields, codec)
  end

  def run(value, {:map, fields}, _codec) when is_map(fields), do: value

  # ---

  defp run_tagged(map, by_tag, codec) do
    case Map.fetch(by_tag, Helper.Map.field(map, @tag_key)) do
      {:ok, spec} -> run_fields(map, %{@payload_key => spec}, codec)
      :error -> map
    end
  end

  defp run_fields(map, fields, codec) do
    Enum.reduce(fields, map, fn {field, spec}, acc ->
      case Helper.Map.key(acc, field) do
        {:ok, key} -> Map.put(acc, key, run(Map.fetch!(acc, key), spec, codec))
        :error -> acc
      end
    end)
  end

  # ===== спека =====

  @doc """
  Проверить форму спеки (compile-time).

  Возвращает саму спеку; при неверной форме — `raise ArgumentError`. Нужна тем, кто
  принимает спеку декларацией (`wire_prims:` шага и подобные): `run/3` строг по спеке,
  и опечатка обязана ломать сборку, а не всплывать расхождением формата на read-пути.
  """
  @spec validate!(term()) :: spec()

  def validate!({:prim, mod} = spec) when is_atom(mod) do
    if not Prim.prim?(mod) do
      raise ArgumentError, "спека {:prim, _} требует Prim-модуль, получено: #{inspect(mod)}"
    end

    spec
  end

  def validate!({:list, inner} = spec) do
    validate!(inner)

    spec
  end

  def validate!({:map, fields} = spec) when is_map(fields) do
    Enum.each(fields, &validate_field!/1)

    spec
  end

  def validate!({:tagged, by_tag} = spec) when is_map(by_tag) do
    Enum.each(by_tag, &validate_tag!/1)

    spec
  end

  def validate!(other) do
    raise ArgumentError,
          "неверная спека Redump: #{inspect(other)}; ожидается {:prim, Mod}, " <>
            "{:map, %{поле => спека}}, {:list, спека} или {:tagged, %{тег => спека}}"
  end

  # ---

  defp validate_field!({field, spec}) when is_atom(field), do: validate!(spec)

  defp validate_field!({field, _spec}) do
    raise ArgumentError,
          "ключ поля спеки {:map, _} должен быть атомом, получено: #{inspect(field)}"
  end

  defp validate_tag!({tag, spec}) when is_binary(tag), do: validate!(spec)

  defp validate_tag!({tag, _spec}) do
    raise ArgumentError, "тег спеки {:tagged, _} должен быть строкой, получено: #{inspect(tag)}"
  end
end
