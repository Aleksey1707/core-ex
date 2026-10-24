defmodule Core.Es.Event.Message do
  @moduledoc """
  Сообщение брокера → событие семейства `<Aggregate>.Event` — `from_message:` подписчика того же
  приложения (`Core.PubSub.MqSubscriberReliable`) на топик `<Aggregate>.Outbox.topic/0`.

      from_message: &Core.Es.Event.Message.load(MyApp.Domain.<BC>.Order.Event, &1)

  Тело сообщения — конверт события, который записал flush write-репозитория: ПДн-значения в нём
  лежат `{"$pd": "<base64>"}` (`docs/rules/23-personal-data.md`). `load/2` проходит тот же шаг
  загрузки, что пути чтения `Core.Es.Store`: `Jason.decode` тела → все `$pd` сообщения одним
  вызовом `open` хранилища ключей → `Core.Config.codec().load(family, wire)` с апкастом.

  | Исход | Ответ | Подписчик |
  |---|---|---|
  | событие, ключ субъекта уничтожен — `%Core.Es.Personal.Destroyed{}` на месте поля | `{:ok, event}` | `on_message` |
  | сбой хранилища ключей | `{:error, %Error{kind: :app}}` | повтор |
  | тело не JSON или tombstone — `:invalid_body` (`ns: :es`, `:domain`) | `{:reject, _}` | DLQ |
  | значение не открылось — `:unreadable_personal_value` | `{:reject, _}` | DLQ |
  | ошибка `load` (`:invalid_envelope`, `:unknown_event_type`, …) | `{:reject, _}` | DLQ |
  | исключение апкаста или `load` на конверте с расшифрованным `$pd` — `:upcast_raised` | `{:reject, _}` | DLQ |

  Конверт без строкового `event_id` не расшифровывается: адреса шифротекста у него нет, и его
  отвергает `load`. Исключение на конверте без `$pd` не перехватывается — его превращает в
  повтор сам подписчик, как раньше.

  Перечитывание `Core.Mq.Dlq.Reader` и возврат из `:failed` идут тем же `from_message`:
  переигранное сообщение расшифровывается так же.
  """

  alias Core.Config
  alias Core.Error
  alias Core.Es
  alias Core.Mq
  alias Core.PubSub

  require Error

  @doc """
  Разобрать сообщение брокера в событие семейства `family` (`<Aggregate>.Event`). Исходы — в
  `@moduledoc`.
  """
  @spec load(module(), Mq.Message.t()) :: PubSub.decode_result(Es.Event.t())

  def load(family, %Mq.Message{body: body}) when is_atom(family) do
    case decode(body) do
      {:ok, wire} -> load_wire(family, wire, Config.codec())
      {:error, %Error{} = error} -> {:reject, error}
    end
  end

  # ---

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, wire} -> {:ok, wire}
      {:error, %Jason.DecodeError{position: position}} -> {:error, invalid_body(%{position: position})}
    end
  end

  defp decode(nil), do: {:error, invalid_body(%{tombstone: true})}

  defp load_wire(family, %{"event_id" => event_id} = wire, codec) when is_binary(event_id) do
    case Es.Store.load_wires([{family, wire}], &codec.load/2) do
      {:ok, [loaded]} -> to_decode_result(loaded)
      {:error, %Error{}} = error -> error
    end
  end

  defp load_wire(family, wire, codec), do: to_decode_result(codec.load(family, wire))

  defp to_decode_result({:ok, event}), do: {:ok, event}
  defp to_decode_result({:error, %Error{} = error}), do: {:reject, error}

  # Тело в `detail` не кладётся: в нём ПДн-значения открытого конверта или шифротекст.
  defp invalid_body(detail) do
    Error.domain(__MODULE__,
      code: :invalid_body,
      ns: :es,
      message: "Тело сообщения — не JSON конверта события",
      detail: detail
    )
  end
end
