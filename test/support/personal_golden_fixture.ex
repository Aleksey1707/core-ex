defmodule Core.PersonalGoldenFixture do
  @moduledoc """
  Строка ключа субъекта и шифротекст для рабочей golden-фикстуры с ПДн-значением
  (`test/support/fixtures/events_sealed`).

  Строка ключа схемы `1` записана под KEK версии 1 из `config/test.exs`, шифротекст фикстуры
  открывается в `"Иван Петров"`. Субъект по умолчанию — `aggregate_id` фикстуры `account.holder_set`.
  """

  alias Core.Context
  alias Core.Es.Personal
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.TestRepo

  @key_id "0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0"
  @wrapped "ZWZnaGlqa2xtbm9wR68CiUYj1Y8uZ4rjdAgIUESTMkz6c0n01YUefqvlV9QnF8TsJbNKROdTkOlexYBv"
  @pd "AQ8eLTxLWkloh3altMPS4fDJysvMzc7P0NHS09SD6PTuFW4GVqytg0oKJFkWNUPjRt64sDqFVm1bKyONh745hynH9j8="
  @event_id "01a09d85-3b21-7c4e-9d3a-5f1e2b7c8a90"
  @subject "01a09d85-3b0d-7db9-b527-fbb1a72396e0"

  @doc "Идентификатор строки ключа субъекта."
  @spec key_id() :: String.t()

  def key_id, do: @key_id

  @doc "`$pd` фикстуры — base64 шифротекста поля `holder`."
  @spec pd() :: String.t()

  def pd, do: @pd

  @doc "Идентификатор события фикстуры — адрес шифротекста."
  @spec event_id() :: String.t()

  def event_id, do: @event_id

  @doc "Субъект фикстуры — владелец ключа."
  @spec subject() :: String.t()

  def subject, do: @subject

  @doc "Записать строку ключа субъекта в транзакции вызывающего."
  @spec put!(String.t()) :: :ok

  def put!(subject \\ @subject) do
    {:ok, key_id} = Ecto.UUID.dump(@key_id)

    TestRepo.query!(
      "INSERT INTO es_subject_keys (id, subject, wrapped_key, kek_version, created_at) VALUES ($1, $2, $3, 1, $4)",
      [key_id, subject, Base.decode64!(@wrapped), NaiveDateTime.utc_now()]
    )

    :ok
  end

  @doc "Уничтожить ключ субъекта фикстуры."
  @spec destroy!() :: :ok

  def destroy! do
    {:ok, subject} = Account.ID.new(@subject)
    :ok = Personal.destroy_key(subject, UserID.new(), Context.new())
  end
end
