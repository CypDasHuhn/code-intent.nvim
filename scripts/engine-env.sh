# shellcheck shell=sh

CINT_ENGINE_ENV_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CINT_ENGINE_RELEASE_TMP=""

engine_env_cleanup() {
  if [ -n "$CINT_ENGINE_RELEASE_TMP" ]; then
    rm -rf "$CINT_ENGINE_RELEASE_TMP"
    CINT_ENGINE_RELEASE_TMP=""
  fi
}

engine_env_fail() {
  echo "FAIL: $*" >&2
  exit 2
}

engine_env_resolve() {
  if [ -n "${CINT_ENGINE_ARTIFACT:-}" ]; then
    [ -f "$CINT_ENGINE_ARTIFACT" ] || engine_env_fail "CINT_ENGINE_ARTIFACT not found: $CINT_ENGINE_ARTIFACT"
    checksum="$CINT_ENGINE_ARTIFACT.sha256"
    if [ -f "$checksum" ]; then
      (cd "$(dirname "$CINT_ENGINE_ARTIFACT")" && sha256sum -c "$(basename "$checksum")") ||
        engine_env_fail "checksum mismatch for $CINT_ENGINE_ARTIFACT"
    fi
    CINT_ENGINE_RELEASE_TMP="$(mktemp -d)"
    tar -xzf "$CINT_ENGINE_ARTIFACT" -C "$CINT_ENGINE_RELEASE_TMP" ||
      engine_env_fail "could not extract $CINT_ENGINE_ARTIFACT"
    server_bin="$(find "$CINT_ENGINE_RELEASE_TMP" -path '*/cint-server/bin/cint-server' -type f -print -quit)"
    schema="$(find "$CINT_ENGINE_RELEASE_TMP" -name protocol.schema.json -type f -print -quit)"
    manifest="$(find "$CINT_ENGINE_RELEASE_TMP" -name RELEASE.json -type f -print -quit)"
    [ -n "$server_bin" ] || engine_env_fail "artifact is missing cint-server/bin/cint-server"
    [ -n "$schema" ] || engine_env_fail "artifact is missing protocol.schema.json"
    [ -n "$manifest" ] || engine_env_fail "artifact is missing RELEASE.json"
    export CINT_SERVER_BIN="$server_bin"
    export CINT_PROTOCOL_SCHEMA="$schema"
    export CINT_ENGINE_RELEASE_MANIFEST="$manifest"
    return
  fi

  if [ "${CI:-}" = "true" ]; then
    engine_env_fail "CINT_ENGINE_ARTIFACT is required in CI; set it to a released cint-engine tarball"
  fi

  engine_root="${CINT_ENGINE_ROOT:-$CINT_ENGINE_ENV_ROOT/../code-intent}"
  export CINT_ENGINE_ROOT="$engine_root"
  export CINT_PROTOCOL_SCHEMA="${CINT_PROTOCOL_SCHEMA:-$engine_root/orchestration/ipc/protocol.schema.json}"
  if [ -z "${CINT_SERVER_BIN:-}" ]; then
    export CINT_SERVER_BIN="$engine_root/apps/server/build/install/cint-server/bin/cint-server"
  fi
}
