#!/data/data/com.termux/files/usr/bin/sh
# Deploys a worker made of several .js modules (only the code; variables, secrets, bindings and cron stay as they are).
#
#   deploy-modules.sh <folder> <worker-name>
#   deploy-modules.sh src pek-sync
#
# The folder must contain index.js (the entry) plus the modules it imports. ~/.cf must set CF_ACCOUNT and CF_TOKEN.
. ~/.cf

dir="${1:-src}"
worker="${2:-$CF_WORKER}"

[ -f "$dir/index.js" ] || { echo "No $dir/index.js"; exit 1; }
[ -n "$worker" ] || { echo "No worker name. Use: deploy-modules.sh $dir <worker-name>"; exit 1; }
{ [ -n "$CF_ACCOUNT" ] && [ -n "$CF_TOKEN" ]; } || { echo "CF_ACCOUNT or CF_TOKEN is missing in ~/.cf"; exit 1; }
case "$worker" in *[!A-Za-z0-9_-]*) echo "Worker names can only use letters, numbers, - and _ : $worker"; exit 1;; esac

set --
for f in "$dir"/*.js; do
  b=$(basename "$f")
  set -- "$@" -F "$b=@$f;type=application/javascript+module"
done

out=$(curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/workers/scripts/$worker/content" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -F 'metadata={"main_module":"index.js"};type=application/json' \
  "$@")

if echo "$out" | grep -Eq '"success": ?true'; then
  echo "Deployed $dir to $worker"
else
  echo "Failed to deploy $dir to $worker:"
  echo "$out"
  exit 1
fi
