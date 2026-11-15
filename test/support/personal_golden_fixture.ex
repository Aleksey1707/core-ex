defmodule Core.PersonalGoldenFixture do
  @moduledoc """
  Строка ключа субъекта для golden-фикстуры с ПДн-значением (`test/support/fixtures/events_sealed`).

  Константы — те же, что в `test/core/es/personal/key_store/pg_test.exs`: строка ключа схемы `1`
  записана под KEK версии 1 из `config/test.exs`, шифротекст фикстуры открывается в `"Иван Петров"`.
  Субъект — `aggregate_id` фикстуры `account.holder_set`.
  """

  alias Core.Es.Personal.Port
  alias Core.TestRepo

  @key_id "0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0"
  @wrapped "ZWZnaGlqa2xtbm9wR68CiUYj1Y8uZ4rjdAgIUESTMkz6c0n01YUefqvlV9QnF8TsJbNKROdTkOlexYBv"
  @subject "01a09d85-3b0d-7db9-b527-fbb1a72396e0"

  @doc "Записать строку ключа субъекта в транзакции вызывающего."
  @spec put!() :: :ok

  def put! do
    {:ok, key_id} = Ecto.UUID.dump(@key_id)

    TestRepo.query!(
      "INSERT INTO es_subject_keys (id, subject, wrapped_key, kek_version, created_at) VALUES ($1, $2, $3, 1, $4)",
      [key_id, @subject, Base.decode64!(@wrapped), NaiveDateTime.utc_now()]
    )

    :ok
  end

  @doc "Уничтожить ключ субъекта фикстуры."
  @spec destroy!() :: :ok

  def destroy!, do: Port.destroy(@subject)
end
