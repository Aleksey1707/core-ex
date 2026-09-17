# 03: Case-модуль проверки `constraint_errors`

**Status:** needs-triage

**What to build:** `use Core.Repo.ConstraintErrorsCase, otp_app:` — проверки по сгенерированным
`__constraint_errors__/0` / `__children_constraint_errors__/0` из `19-testing.md`, «`constraint_errors`»
(включая «read-репозиторий не объявляет `constraint_errors`»).

**Why:** функции генерируются ради этого теста, а сам тест пишет каждое приложение (копии почти идентичны).

- [ ] case-модуль и тест; строка ратчета в `app/19-testing.md` — на него; CHANGELOG «Новое»
