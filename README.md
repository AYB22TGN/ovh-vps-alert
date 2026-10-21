# ovh-vps-alert

Alerte Telegram quand un VPS OVHcloud redevient disponible (ou repasse en rupture) en **Linux** dans un **datacenter européen**.

- Toutes les 5 min (cron GitHub Actions, best-effort) + lancement manuel (`workflow_dispatch`).
- Source : `GET https://eu.api.ovh.com/v1/vps/order/rule/datacenter?ovhSubsidiary=FR&planCode=<plan>` (public, sans auth).
- Filtre : `code` commençant par `eu-` (GRA, SBG, RBX, LIM/DE, ERI/UK, WAW, MIL), champ `linuxStatus`.
- État comparé à `state.json` (commité par le workflow) : alerte **uniquement** sur `out-of-stock → available` et `available → out-of-stock`.
- Premier passage d'un plan : état initialisé **sans alerte**.
- Si l'API OVH ou Telegram échoue, l'état du plan n'est pas modifié (retentative au passage suivant).

## Configuration

| Quoi | Où |
|---|---|
| Plans surveillés | `plans.txt` (un `planCode` par ligne, ex. `vps-2027-model3`) |
| Secrets | `TG_TOKEN` (token du bot), `TG_CHAT` (chat id) |
| Filiale OVH | variable d'env `OVH_SUBSIDIARY` (défaut `FR`) |

```bash
gh secret set TG_TOKEN -R <owner>/ovh-vps-alert
gh secret set TG_CHAT  -R <owner>/ovh-vps-alert
```

## Test local

```bash
DRY_RUN=1 ./check.sh   # affiche les messages au lieu de les envoyer
```

> GitHub désactive les workflows planifiés d'un repo public après 60 jours sans activité : le commit de `state.json` à chaque changement de stock suffit en général, sinon réactiver depuis l'onglet Actions.
