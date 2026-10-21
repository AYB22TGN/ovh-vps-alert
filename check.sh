#!/usr/bin/env bash
# Surveille la disponibilité Linux des VPS OVH dans les datacenters européens
# et envoie une alerte Telegram uniquement sur changement d'état.
# Dépendances : bash, curl, jq.
set -euo pipefail

SUBSIDIARY="${OVH_SUBSIDIARY:-FR}"
PLANS_FILE="${PLANS_FILE:-plans.txt}"
STATE_FILE="${STATE_FILE:-state.json}"
API="https://eu.api.ovh.com/v1/vps/order/rule/datacenter"
LANG_PATH="$(echo "$SUBSIDIARY" | tr '[:upper:]' '[:lower:]')"
DRY_RUN="${DRY_RUN:-0}"   # 1 = affiche les messages au lieu de les envoyer

[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

send_telegram() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf -- '--- [dry-run] message Telegram ---\n%s\n' "$1"
    return 0
  fi
  : "${TG_TOKEN:?TG_TOKEN manquant}" "${TG_CHAT:?TG_CHAT manquant}"
  curl -fsS --retry 3 --max-time 20 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" > /dev/null
}

if [[ "${TEST_TELEGRAM:-0}" == "1" ]]; then
  send_telegram "✅ <b>ovh-vps-alert</b> : test depuis GitHub Actions, les secrets fonctionnent."
  echo "Message de test envoyé"
fi

plans=$(grep -vE '^\s*(#|$)' "$PLANS_FILE" | tr -d '[:blank:]\r')
state=$(cat "$STATE_FILE")

for plan in $plans; do
  url="${API}?ovhSubsidiary=${SUBSIDIARY}&planCode=${plan}"
  if ! resp=$(curl -fsS --retry 3 --max-time 30 "$url"); then
    echo "::warning::API OVH injoignable pour ${plan}, état conservé"
    continue
  fi

  # Datacenters européens uniquement (code eu-*), statut Linux.
  if ! current=$(jq -ce '
      if (.datacenters | type) != "array" then error("format inattendu") else . end
      | [.datacenters[] | select(.code | startswith("eu-"))
         | {key: .code, value: {name: .datacenter, status: .linuxStatus}}]
      | from_entries' <<<"$resp"); then
    echo "::warning::Réponse inattendue pour ${plan}, état conservé"
    continue
  fi

  previous=$(jq -c --arg p "$plan" '.[$p] // null' <<<"$state")
  if [[ "$previous" == "null" ]]; then
    echo "${plan} : premier passage, état initialisé sans alerte"
    state=$(jq -c --arg p "$plan" --argjson c "$current" '.[$p] = $c' <<<"$state")
    continue
  fi

  # Transitions : ancien statut != nouveau, uniquement entre available et out-of-stock
  # (un DC absent de l'ancien état est traité comme out-of-stock).
  changes=$(jq -c --argjson old "$previous" '
      to_entries
      | map({code: .key, name: .value.name, new: .value.status,
             old: ($old[.key].status // "out-of-stock")})
      | map(select(.old != .new and (.new == "available" or .old == "available")))' <<<"$current")

  order_url="https://www.ovhcloud.com/${LANG_PATH}/vps/configurator/?planCode=${plan}"
  sent_ok=1
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    name=$(jq -r .name <<<"$c"); code=$(jq -r .code <<<"$c")
    old=$(jq -r .old <<<"$c");   new=$(jq -r .new <<<"$c")
    if [[ "$new" == "available" ]]; then
      head="🟢 <b>${plan}</b> DISPONIBLE"
    else
      head="🔴 <b>${plan}</b> en rupture"
    fi
    msg=$(printf '%s\nDatacenter : <b>%s</b> (%s)\nLinux : %s → %s\n<a href="%s">Commander sur OVHcloud</a>' \
      "$head" "$name" "$code" "$old" "$new" "$order_url")
    echo "${plan} ${code} : ${old} → ${new}"
    if ! send_telegram "$msg"; then
      echo "::error::Échec d'envoi Telegram pour ${plan} ${code}"
      sent_ok=0
    fi
  done < <(jq -c '.[]' <<<"$changes")

  # Si un envoi a échoué, on garde l'ancien état pour retenter au prochain passage.
  if [[ "$sent_ok" == "1" ]]; then
    state=$(jq -c --arg p "$plan" --argjson c "$current" '.[$p] = $c' <<<"$state")
  fi
done

jq -S . <<<"$state" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
