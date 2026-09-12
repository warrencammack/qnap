#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-Composer/transmission.env}"

if [ ! -r "$ENV_FILE" ]; then
  printf '%s\n' "Missing readable credentials file: $ENV_FILE" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

: "${USER:?USER missing from credentials file}"
: "${PASS:?PASS missing from credentials file}"

transmission-remote -n "$USER:$PASS" --no-alt-speed --no-alt-speed-scheduler
transmission-remote -n "$USER:$PASS" -si
