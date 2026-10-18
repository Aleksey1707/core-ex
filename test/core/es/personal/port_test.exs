defmodule Core.Es.Personal.PortTest do
  use Core.DataCase, async: true

  alias Core.Es.Personal.Port
  alias Core.Telemetry

  setup do
    test = self()
    id = {__MODULE__, make_ref()}

    # Обработчик глобален, а тесты идут параллельно: событие чужого процесса тесту не нужно.
    :telemetry.attach_many(
      id,
      [Telemetry.event([:es, :personal, :call]), Telemetry.event([:es, :personal, :open])],
      fn event, measurements, metadata, _config ->
        if self() == test, do: send(test, {:telemetry, List.last(event), measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "telemetry вызова порта" do
    test "op и result на каждый вызов, длительность — измерение" do
      subject = Ecto.UUID.generate()

      {:ok, [sealed]} = Port.seal([{subject, "aad", "Иван"}])
      {:ok, [_index]} = Port.index([{"scope", ["key"]}])
      :ok = Port.destroy(subject)

      assert_receive {:telemetry, :call, %{duration: duration}, %{op: :seal, result: :ok}} when is_integer(duration)
      assert_receive {:telemetry, :call, _measurements, %{op: :index, result: :ok}}
      assert_receive {:telemetry, :call, _measurements, %{op: :destroy, result: :ok}}

      {:error, _reason} = Port.seal([{subject, "aad", "Пётр"}])
      assert_receive {:telemetry, :call, _measurements, %{op: :seal, result: :refused} = metadata}
      assert Map.keys(metadata) == [:op, :result]

      {:ok, [:destroyed]} = Port.open([{sealed, "aad"}])
      assert_receive {:telemetry, :call, _measurements, %{op: :open, result: :ok}}
    end

    test "сбой хранилища — result: :error" do
      TestRepo.query!("SET LOCAL search_path TO no_such_schema")

      {:error, _reason} = Port.seal([{Ecto.UUID.generate(), "aad", "Иван"}])

      assert_receive {:telemetry, :call, _measurements, %{op: :seal, result: :error}}
    end
  end

  describe "telemetry исходов расшифровки" do
    test "count по outcome в пачке" do
      [live, gone] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      {:ok, [sealed_live, sealed_gone]} = Port.seal([{live, "aad", "Иван"}, {gone, "aad", "Пётр"}])
      :ok = Port.destroy(gone)

      {:ok, _outcomes} =
        Port.open([{sealed_live, "aad"}, {sealed_live, "aad"}, {sealed_gone, "aad"}, {"мусор", "aad"}])

      assert_receive {:telemetry, :open, %{count: 2}, %{outcome: :opened}}
      assert_receive {:telemetry, :open, %{count: 1}, %{outcome: :destroyed}}
      assert_receive {:telemetry, :open, %{count: 1}, %{outcome: :unreadable}}
    end
  end

  describe "address/1" do
    test "склейка и перестановка частей дают другой адрес" do
      assert Port.address(["ab", "c"]) != Port.address(["a", "bc"])
      assert Port.address(["a", "b"]) != Port.address(["b", "a"])
      assert Port.address(["a", ""]) != Port.address(["a"])
    end
  end
end
