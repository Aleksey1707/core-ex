#!/usr/bin/env bash
# Самопроверка храповика: исходное состояние, пропавшее предупреждение, лишнее, сдвиг строк.
# Запуск: bash ratchet/selftest.sh (из каталога prototype). Файлы фикстуры восстанавливаются.
set -u

here="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$here/consumer"
backup="$(mktemp -d)"
trap 'cp "$backup"/p2_evolve.ex "$fixture"/lib/scenarios/p2_evolve.ex;
      cp "$backup"/p0.ex "$fixture"/lib/scenarios/p0.ex;
      cp "$backup"/usecase.ex "$fixture"/lib/blind/usecase.ex;
      rm -rf "$backup"' EXIT

cp "$fixture"/lib/scenarios/p2_evolve.ex "$fixture"/lib/scenarios/p0.ex "$fixture"/lib/blind/usecase.ex "$backup"/

run() {
  echo "== $1"
  out="$(cd "$fixture" && mix run --no-start --no-compile ../ratchet/check_warnings.exs 2>/dev/null)"
  code=$?
  echo "$out" | grep -E '^(ratchet|  )'
  echo "exit=$code"
}

restore() {
  cp "$backup"/p2_evolve.ex "$fixture"/lib/scenarios/p2_evolve.ex
  cp "$backup"/p0.ex "$fixture"/lib/scenarios/p0.ex
  cp "$backup"/usecase.ex "$fixture"/lib/blind/usecase.ex
}

run "1. исходное состояние"

# C1 починен: у BadEvolveMissing появилась clause Closed — предупреждения больше нет.
sed -i '0,/^  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}$/s//&\n  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}/' \
  "$fixture"/lib/scenarios/p2_evolve.ex
run "2. пропавшее предупреждение (C1 починен, маркер остался)"
restore

# Новая ошибка в корректном потребителе без маркера.
sed -i 's/^  def fold_history(%Account{} = state, events) when is_list(events),$/  def typo(%Account{} = state), do: state.nmae\n\n&/' \
  "$fixture"/lib/blind/usecase.ex
run "3. лишнее предупреждение (опечатка в lib/blind/usecase.ex)"
restore

# Сдвиг строк: 7 строк комментариев и пустых строк в начало файла сценариев.
{ printf '# сдвиг\n\n# сдвиг\n\n# сдвиг\n\n\n'; cat "$backup"/p0.ex; } > "$fixture"/lib/scenarios/p0.ex
run "4. сдвиг строк в p0.ex на 7"
restore

# Для сравнения: эталон строками `file:line: title [mfa]` (--dump) при том же сдвиге.
dump() {
  (cd "$fixture" && mix run --no-start --no-compile ../ratchet/check_warnings.exs --dump 2>/dev/null | grep '^lib/')
}

dump > "$backup"/golden_before.txt
{ printf '# сдвиг\n\n# сдвиг\n\n# сдвиг\n\n\n'; cat "$backup"/p0.ex; } > "$fixture"/lib/scenarios/p0.ex
dump > "$backup"/golden_after.txt
restore
sed -E 's/:[0-9]+:/:/' "$backup"/golden_before.txt > "$backup"/nolines_before.txt
sed -E 's/:[0-9]+:/:/' "$backup"/golden_after.txt > "$backup"/nolines_after.txt
echo "== 5. эталон file:line при сдвиге на 7: строк $(wc -l < "$backup"/golden_before.txt)," \
  "разошлось $(diff "$backup"/golden_before.txt "$backup"/golden_after.txt | grep -c '^>')"
echo "== 5b. эталон file: title [mfa] без строки: разошлось" \
  "$(diff "$backup"/nolines_before.txt "$backup"/nolines_after.txt | grep -c '^>')"
