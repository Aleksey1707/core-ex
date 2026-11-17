defmodule ConsumerTest.NestedPersonal do
  @moduledoc """
  Вложенные ПДн-места шага маршрута: тип чтения шага (`Step.t()`) несёт уничтоженное значение на
  каждом ПДн-месте, и функция Prim над ним недостижима.

  D7 — получатель шага; D7b — контент шага; D7c — прочитанный шаг в конструктор нагрузки: шаг
  записи (`Step.write_t()`) уничтоженного значения не допускает, но сборка сужения полей структуры
  не видит — ловит поведение, а не тип.
  """

  alias Consumer.Domain.Sales.Itinerary
  alias Consumer.Domain.Sales.Itinerary.Step
  alias Core.Es.Personal.Destroyed

  # D7 — уничтоженный получатель вложенного шага
  def d7_destroyed_recipient(%Step{recipient: %Destroyed{} = recipient}),
    # expect: incompatible types given to Consumer.Domain.Sales.Itinerary.Recipient.value/1
    do: Itinerary.Recipient.value(recipient)

  # D7b — уничтоженный контент вложенного шага
  def d7b_destroyed_content(%Step{content: %Destroyed{} = content}),
    # expect: incompatible types given to Consumer.Domain.Sales.Itinerary.Content.value/1
    do: Itinerary.Content.value(content)

  # D7c — прочитанные шаги в конструктор нагрузки нового события: тип записи шага
  def d7c_read_steps_into_payload(steps), do: Itinerary.Event.Planned.Payload.new(steps)
end
