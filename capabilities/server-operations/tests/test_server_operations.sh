#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
exec ruby "$project_root/capabilities/server-operations/tests/test_server_operations.rb"
