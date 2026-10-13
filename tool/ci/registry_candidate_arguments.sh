# Source from the existing workflow: strict boolean intent, private by default.
# Bash 3 + nounset needs ${registry_args[@]+"${registry_args[@]}"} at call sites.
registry_args=()
case "${ARCHWAY_REGISTRY_READY-}" in
  false) ;;
  true) registry_args=(--registry-ready) ;;
  *) echo 'Registry candidate intent must be true or false' >&2; return 1 ;;
esac
