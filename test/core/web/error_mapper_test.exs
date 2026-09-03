defmodule Core.Web.ErrorMapperTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Web

  require Error

  defp domain(code, message \\ "сообщение домена") do
    Error.domain(code: code, ns: :test, message: message)
  end

  defp app(code), do: Error.app(code: code, ns: :test)

  test "version_mismatch → 412 с доменным текстом" do
    assert {412, :diff_version, "версия не та", nil} =
             Web.ErrorMapper.map(domain(:version_mismatch, "версия не та"))
  end

  test "коды авторизации → 401 с константой и debug-логом" do
    for code <- ~w(unauthorized auth_failed invalid_token session_not_found)a do
      assert {401, :auth_error, "Не авторизован", :debug} =
               Web.ErrorMapper.map(domain(code, "токен протух: user=42"))
    end
  end

  test "access_denied → 403 с доменным текстом" do
    assert {403, :error, "нет прав", nil} =
             Web.ErrorMapper.map(domain(:access_denied, "нет прав"))
  end

  test "прочая доменная ошибка → 400" do
    assert {400, :domain_error, "сообщение домена", nil} = Web.ErrorMapper.map(domain(:invalid))
  end

  test "прикладная ошибка → 500 с шаблоном и error-логом" do
    assert {500, :critical, "Произошла непредвиденная ошибка", :error} =
             Web.ErrorMapper.map(app(:write_failed))
  end

  test "не-%Error{} → 500" do
    assert {500, :critical, _, :error} = Web.ErrorMapper.map(:timeout)
    assert {500, :critical, _, :error} = Web.ErrorMapper.map(%RuntimeError{message: "бум"})
  end

  test "auth_codes и тексты переопределяются опциями" do
    opts = [auth_codes: ~w(no_session)a, unauthorized_message: "Нет", critical_message: "Ой"]

    assert {401, :auth_error, "Нет", :debug} = Web.ErrorMapper.map(domain(:no_session), opts)
    assert {400, :domain_error, _, nil} = Web.ErrorMapper.map(domain(:unauthorized), opts)
    assert {500, :critical, "Ой", :error} = Web.ErrorMapper.map(app(:boom), opts)
  end
end
