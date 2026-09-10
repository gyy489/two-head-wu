#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
exec ruby "$project_root/capabilities/remote-work-bootstrap/tests/test_remote_work_bootstrap.rb"
