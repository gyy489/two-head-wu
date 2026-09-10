import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "skills-manager"
LOADER = importlib.machinery.SourceFileLoader("two_head_wu_skills_manager", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MANAGER = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = MANAGER
LOADER.exec_module(MANAGER)


class TreeDigestTest(unittest.TestCase):
    def test_digest_is_deterministic_and_ignores_runtime_cache(self):
        with tempfile.TemporaryDirectory(prefix="two-head-wu-digest-") as directory:
            root = Path(directory)
            (root / "b.txt").write_text("b\n", encoding="utf-8")
            (root / "a.txt").write_text("a\n", encoding="utf-8")
            first = MANAGER.tree_digest(root)
            self.assertEqual(first, MANAGER.tree_digest(root))

            cache = root / "__pycache__"
            cache.mkdir()
            (cache / "ignored.pyc").write_bytes(b"ignored")
            self.assertEqual(first, MANAGER.tree_digest(root))

            (root / "a.txt").write_text("changed\n", encoding="utf-8")
            self.assertNotEqual(first, MANAGER.tree_digest(root))

    def test_digest_tracks_executable_mode_and_symlink_target(self):
        with tempfile.TemporaryDirectory(prefix="two-head-wu-digest-") as directory:
            root = Path(directory)
            script = root / "run.sh"
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            link = root / "entry"
            link.symlink_to("run.sh")
            initial = MANAGER.tree_digest(root)

            script.chmod(script.stat().st_mode | 0o100)
            executable = MANAGER.tree_digest(root)
            self.assertNotEqual(initial, executable)

            link.unlink()
            link.symlink_to("other.sh")
            self.assertNotEqual(executable, MANAGER.tree_digest(root))


class EnsureLayoutTest(unittest.TestCase):
    def test_layout_creates_compatibility_catalog_root(self):
        with tempfile.TemporaryDirectory(prefix="two-head-wu-layout-") as directory:
            root = Path(directory)
            directories = {
                "ACTIVE_DIR": root / ".active",
                "AUDIT_DIR": root / "audits",
                "SKILL_CONTEXTS_DIR": root / "contexts",
                "SKILL_LOGS_DIR": root / "logs",
                "SKILL_ARTIFACTS_DIR": root / "artifacts",
                "SKILL_OUTPUTS_DIR": root / "outputs",
                "SKILL_DOCS_DIR": root / "docs",
                "SKILL_INVENTORIES_DIR": root / "inventories",
                "RELEASE_STORE": root / "releases",
            }
            with mock.patch.multiple(
                MANAGER,
                SOURCE_DIRS={"test": root / "source"},
                MANAGED_SOURCE_KEYS=("test",),
                **directories,
            ):
                MANAGER.ensure_layout()
                self.assertTrue(MANAGER.ACTIVE_DIR.is_dir())


class CompatibilityRelinkTest(unittest.TestCase):
    def test_repeated_directory_drift_gets_a_unique_recoverable_backup(self):
        with tempfile.TemporaryDirectory(prefix="two-head-wu-relink-") as directory:
            root = Path(directory)
            active_root = root / ".active"
            skills_root = root / "skills"
            snapshot = root / "release"
            snapshot.mkdir()
            (snapshot / "SKILL.md").write_text("release\n", encoding="utf-8")

            with mock.patch.multiple(
                MANAGER,
                ACTIVE_DIR=active_root,
                SKILLS_ROOT=skills_root,
            ):
                for content in ("first\n", "second\n"):
                    active = active_root / "example"
                    if active.is_symlink():
                        active.unlink()
                    active.mkdir(parents=True)
                    (active / "SKILL.md").write_text(content, encoding="utf-8")
                    MANAGER.relink_compatibility_entry(
                        "example", snapshot, backup_directory=True
                    )
                    self.assertTrue(active.is_symlink())
                    self.assertEqual(active.resolve(), snapshot.resolve())

            backup_root = skills_root / ".trash" / "v2-active-source-backup"
            self.assertEqual(
                (backup_root / "example" / "SKILL.md").read_text(encoding="utf-8"),
                "first\n",
            )
            self.assertEqual(
                (backup_root / "example.repeat-2" / "SKILL.md").read_text(
                    encoding="utf-8"
                ),
                "second\n",
            )


if __name__ == "__main__":
    unittest.main()
