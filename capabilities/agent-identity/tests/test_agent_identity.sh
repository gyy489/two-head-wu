#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
ruby "$project_root/capabilities/agent-identity/tests/test_agent_identity.rb"
exec ruby "$project_root/capabilities/agent-identity/tests/test_thread_lifecycle.rb"
