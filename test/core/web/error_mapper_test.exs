defmodule Core.Web.ErrorMapperTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Web

  require Error

  defp domain(code, message \\ "сообщение домена") do
    Error.domain(code: code, ns: :test, message: message)
  end

  defp app(code), do: Error.app(code: code, ns: :test)

  defp body(code, message, data \\ %{}),
    do: %{status: "error", data: data, code: code, message: message}

  @critical %{
    status: "error",
    data: %{},
    code: "internal_error",
    message: "Произошла непредвиденная ошибка"
  }

  test "version_mismatch → 412 с доменным кодом и текстом" do
    assert {412, body("test/version_mismatch", "версия не та"), nil} ==
             Web.ErrorMapper.map(domain(:version_mismatch, "версия не та"))
  end

  test "прикладная ошибка с доменным кодом → 500 с шаблоном, код и текст наружу не уходят" do
    assert {500, @critical, :error} == Web.ErrorMapper.map(app(:version_mismatch))
    assert {500, @critical, :error} == Web.ErrorMapper.map(app(:access_denied))
  end

  test "коды авторизации → 401 с константами и debug-логом" do
    for code <- ~w(unauthorized auth_failed invalid_token session_not_found)a do
      assert {401, body("not_authorized", "Не авторизован"), :debug} ==
               Web.ErrorMapper.map(domain(code, "токен протух: user=42"))
    end
  end

  test "access_denied → 403 с доменным кодом и текстом" do
    assert {403, body("test/access_denied", "нет прав"), nil} ==
             Web.ErrorMapper.map(domain(:access_denied, "нет прав"))
  end

  test "прочая доменная ошибка → 400 с кодом ns/code" do
    assert {400, body("test/invalid", "сообщение домена"), nil} == Web.ErrorMapper.map(domain(:invalid))
  end

  test "доменный not_found → 400, а не 404" do
    assert {400, body("test/not_found", "не найдено"), nil} ==
             Web.ErrorMapper.map(domain(:not_found, "не найдено"))
  end

  test "прикладная ошибка → 500 с шаблоном и error-логом" do
    assert {500, @critical, :error} == Web.ErrorMapper.map(app(:write_failed))
  end

  test "не-%Error{} → 500" do
    assert {500, @critical, :error} == Web.ErrorMapper.map(:timeout)
    assert {500, @critical, :error} == Web.ErrorMapper.map(%RuntimeError{message: "бум"})
  end

  describe "множество ошибок" do
    defp many(elements),
      do: Error.many(code: :invalid, ns: :form, message: "форма невалидна", errors: elements)

    test "доменный контейнер отдаёт состав в data.errors" do
      error = many([domain(:blank, "имя пусто"), domain(:past, "срок в прошлом")])

      errors = [%{code: "test/blank", message: "имя пусто"}, %{code: "test/past", message: "срок в прошлом"}]

      assert {400, body("form/invalid", "форма невалидна", %{errors: errors}), nil} ==
               Web.ErrorMapper.map(error)
    end

    test "прикладной контейнер состава не отдаёт" do
      error = many([domain(:blank, "имя пусто"), app(:write_failed)])

      assert {500, @critical, :error} == Web.ErrorMapper.map(error)
    end

    test "контейнер с кодом авторизации состава не отдаёт" do
      error =
        Error.many(
          code: :unauthorized,
          ns: :form,
          message: "нет сессии",
          errors: [domain(:blank, "имя пусто")]
        )

      assert {401, body("not_authorized", "Не авторизован"), :debug} == Web.ErrorMapper.map(error)
    end
  end

  describe "by_status/2 — ошибка до контроллера" do
    test "4xx → имя статуса кодом и фраза статуса текстом" do
      assert body("bad_request", "Bad Request") == Web.ErrorMapper.by_status(400)
      assert body("not_found", "Not Found") == Web.ErrorMapper.by_status(404)
      assert body("unsupported_media_type", "Unsupported Media Type") == Web.ErrorMapper.by_status(415)
    end

    test "4xx вне таблицы Plug → как 400" do
      assert body("bad_request", "Bad Request") == Web.ErrorMapper.by_status(499)
    end

    test "5xx → шаблон маппера, текст переопределяется опцией" do
      assert @critical == Web.ErrorMapper.by_status(500)
      assert @critical == Web.ErrorMapper.by_status(503)
      assert body("internal_error", "Ой") == Web.ErrorMapper.by_status(502, critical_message: "Ой")
    end
  end

  test "auth_codes и тексты переопределяются опциями" do
    opts = [auth_codes: ~w(no_session)a, unauthorized_message: "Нет", critical_message: "Ой"]

    assert {401, body("not_authorized", "Нет"), :debug} ==
             Web.ErrorMapper.map(domain(:no_session), opts)

    assert {400, %{code: "test/unauthorized"}, nil} = Web.ErrorMapper.map(domain(:unauthorized), opts)
    assert {500, body("internal_error", "Ой"), :error} == Web.ErrorMapper.map(app(:boom), opts)
  end
end
