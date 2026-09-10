#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
exec ruby "$project_root/capabilities/skills-dashboard/tests/test_skills_dashboard.rb"
