defmodule Core.Web.CriticalErrorTest do
  # Тестовый режим SDK держит конфигурацию и пойманные события на тест; общая на VM только таблица
  # дедупликации — она выключена конфигурацией теста.
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.PrimFixture.Sensitive
  alias Core.Web.CriticalError
  alias Sentry.Test

  require Error

  setup do
    Test.setup_sentry(dedup_events: false)
  end

  test "исключение — событие исключения со stacktrace, id — event_id события" do
    {exception, stacktrace} = raised()

    id = CriticalError.report(exception, stacktrace)

    assert [%Sentry.Event{event_id: ^id} = event] = Test.pop_sentry_reports()
    assert id =~ ~r/\A[0-9a-f]{32}\z/
    assert event.original_exception == %RuntimeError{message: "сбой"}
    assert [%{type: "RuntimeError", stacktrace: %{frames: [_ | _]}}] = event.exception
  end

  test "в службу уходит событие с тем же идентификатором", %{bypass: bypass} do
    ref = Test.setup_bypass_envelope_collector(bypass, type: "event")

    id = CriticalError.report({:timeout, :ledger}, nil)

    assert [%{"event_id" => ^id}] = Test.collect_sentry_events(ref, 1, timeout: 30_000)
  end

  test "%Error{} — сообщение с текстом ошибки, группировка по ns/code, ошибка в доп. данных" do
    error = Error.app(code: :ledger_unavailable, ns: :billing, message: "журнал недоступен")

    id = CriticalError.report(error, nil)

    assert [%Sentry.Event{event_id: ^id} = event] = Test.pop_sentry_reports()
    assert event.message.formatted == "Прикладная ошибка API: журнал недоступен"
    assert event.fingerprint == ["billing/ledger_unavailable"]
    assert event.extra.error == inspect(error)
    assert event.exception == []
  end

  test "прочий term — сообщение «Необработанная ошибка API», причина в доп. данных, stacktrace при событии" do
    {_exception, stacktrace} = raised()

    id = CriticalError.report({:timeout, :ledger}, stacktrace)

    assert [%Sentry.Event{event_id: ^id} = event] = Test.pop_sentry_reports()
    assert event.message.formatted == "Необработанная ошибка API"
    assert event.extra.reason == "{:timeout, :ledger}"
    assert [%{stacktrace: %{frames: [_ | _]}}] = event.threads
  end

  test "значение Prim с sensitive: true в доп. данных скрыто" do
    secret = Sensitive.new!("пароль-клиента")
    error = Error.app(code: :ledger_unavailable, ns: :billing, detail: %{token: secret})

    CriticalError.report(error, nil)
    CriticalError.report({:rejected, secret}, nil)

    assert [%Sentry.Event{extra: %{error: error}}, %Sentry.Event{extra: %{reason: reason}}] =
             Test.pop_sentry_reports()

    assert error =~ "Sensitive"
    assert reason =~ "Sensitive"
    refute error =~ "пароль-клиента"
    refute reason =~ "пароль-клиента"
  end

  test "без DSN — записи нет, nil" do
    Test.Config.put(dsn: nil)

    assert nil == CriticalError.report({:timeout, :ledger}, nil)
  end

  test "событие отброшено SDK — nil" do
    Test.Config.put(before_send: fn _event -> false end)

    assert nil == CriticalError.report({:timeout, :ledger}, nil)
    assert [] == Test.pop_sentry_reports()
  end

  defp raised do
    raise "сбой"
  rescue
    exception -> {exception, __STACKTRACE__}
  end
end
