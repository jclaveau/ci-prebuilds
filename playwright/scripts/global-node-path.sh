#!/bin/sh
# Echo a NODE_PATH that covers wherever `playwright` was installed globally.
#
# Usage:  export NODE_PATH="$(sh playwright/scripts/global-node-path.sh)"
#
# - `playwright` is a global install in these images, and every caller is
#   CommonJS precisely so NODE_PATH resolution applies — ESM ignores it.
# - Both package managers are tried: our images install it with pnpm, the
#   official control image bakes it with npm.
# - pnpm 11 moved the global store, which is what broke every caller at once
#   when the v11 bump landed. `pnpm root -g` used to name the global
#   node_modules directory itself; it now names its grandparent, with a
#   content-addressed directory in between (`global/v11/<hash>/node_modules`).
#   Each layout is matched on its own so that pnpm 10's reply does not also
#   glob a package's OWN nested node_modules onto the path, where it could
#   shadow a top-level install.
pnpm_root="$(pnpm root -g 2>/dev/null)"
case "$pnpm_root" in
  */node_modules) set -- "$pnpm_root" ;;
  *)              set -- "$pnpm_root"/*/node_modules ;;
esac

node_path=""
for root in "$@" "$(npm root -g 2>/dev/null)"; do
  if [ -d "$root" ]; then
    node_path="${node_path:+$node_path:}$root"
  fi
done
echo "$node_path"
