#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
actual="$($package_root/adapters/hello --name Codex)"

ruby -rjson -e '
  payload = JSON.parse(ARGV.fetch(0))
  abort "unexpected message" unless payload["message"] == "Hello, Codex!"
  abort "unexpected interface" unless payload["interface"] == "hello.greet.v1"
' "$actual"

echo "hello-capability: PASS"
