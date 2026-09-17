#!/usr/bin/env bash
# Самопроверка сверки: исходное состояние, ожидание без предупреждения, предупреждение без ожидания,
# сдвиг строк. Запуск из каталога фикстуры: `bash selftest.sh`. Правки фикстуры откатываются.
set -u
cd "$(dirname "$0")"
export MIX_ENV=dev

probe=lib/scenarios/zz_selftest.ex
shifted=lib/scenarios/execute.ex
backup="$(mktemp)"
cp "$shifted" "$backup"
trap 'cp "$backup" "$shifted"; rm -f "$backup" "$probe"' EXIT

failed=0

check() {
  local title="$1" expected_exit="$2" expected_line="$3"
  local out code
  out="$(mix run --no-start --no-compile check.exs 2>&1)"
  code=$?

  if [ "$code" -eq "$expected_exit" ] && grep -q -- "$expected_line" <<<"$out"; then
    echo "ok   — $title"
  else
    echo "FAIL — $title: код $code, ожидался $expected_exit со строкой «$expected_line»"
    tail -n 20 <<<"$out"
    failed=1
  fi
}

check "исходное состояние" 0 "consumer-check: ok"

cat > "$probe" <<'PROBE'
defmodule Consumer.S.SelftestMissing do
  # expect: incompatible types given to Consumer.Account.execute/2
  def fine, do: :ok
end
PROBE
check "ожидание без предупреждения" 1 "нет предупреждения: $probe:3"
rm -f "$probe"

cat > "$probe" <<'PROBE'
defmodule Consumer.S.SelftestExtra do
  def typo(%Consumer.Account{} = state), do: state.nmae
end
PROBE
check "предупреждение без ожидания" 1 "лишнее: $probe:2: unknown key .nmae"
rm -f "$probe"

{ printf '# сдвиг\n\n# сдвиг\n\n# сдвиг\n\n\n'; cat "$backup"; } > "$shifted"
check "сдвиг строк на 7" 0 "consumer-check: ok"
cp "$backup" "$shifted"

exit "$failed"
