defmodule Core.Es.Personal.StateTest do
  use ExUnit.Case, async: true

  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.State
  alias Core.Telemetry

  defmodule Wrap do
    @moduledoc false

    defstruct [:value]
  end

  describe "dump/1 и load/1" do
    test "уничтоженное значение — маркер `{\"$pd\": null}` и обратно" do
      assert State.dump(%Destroyed{}) == %{"$pd" => nil}
      assert State.load(%{"$pd" => nil}) == %Destroyed{}
    end

    test "обход на любой глубине: список, словарь, struct" do
      value = %Wrap{
        value: %{
          "items" => [%Destroyed{}, "открытое"],
          "nested" => %Wrap{value: %Destroyed{}}
        }
      }

      dumped = %Wrap{
        value: %{
          "items" => [%{"$pd" => nil}, "открытое"],
          "nested" => %Wrap{value: %{"$pd" => nil}}
        }
      }

      assert State.dump(value) == dumped
      assert State.load(dumped) == value
    end

    test "живое ПДн остаётся открытым, карта с лишним ключом — не маркер" do
      value = %{"phone" => "+7 900 000-00-00", "flags" => [1, 2]}

      assert State.dump(value) == value
      assert State.load(value) == value

      assert State.load(%{"$pd" => nil, "other" => 1}) == %{"$pd" => nil, "other" => 1}
    end
  end

  test "к хранилищу ключей не обращается" do
    test = self()
    id = {__MODULE__, make_ref()}

    # Порт зовётся в процессе вызывающего: событие чужого async-теста в почту не попадает.
    :ok =
      :telemetry.attach(
        id,
        Telemetry.event([:es, :personal, :call]),
        fn _event, _measurements, _metadata, config ->
          if self() == config, do: send(test, :personal_call)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    state = %Wrap{value: [%Destroyed{}, "открытое"]}

    assert State.load(State.dump(state)) == state
    refute_received :personal_call
  end
end
