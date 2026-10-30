from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_gateway_discovery import ERROR, MODULE


BREW = "/opt/homebrew/bin/brew"
AZURE = "/opt/homebrew/bin/az"
LOGIN_FLAG = "--skip-subscription-discovery"


class HomebrewFixture:
    def __init__(self, formula=None, cask=None, fail=None, interrupt=None):
        self.formula = formula
        self.cask = cask
        self.fail = fail
        self.interrupt = interrupt
        self.calls = []
        self.options = []

    def run(self, arguments, **options):
        if str(arguments[0]) != BREW:
            raise AssertionError("Unexpected executable: " + str(arguments[0]))
        command = tuple(str(arg) for arg in arguments[1:])
        self.calls.append(command)
        self.options.append(options)
        if command == self.interrupt:
            raise KeyboardInterrupt()
        if command == self.fail:
            return subprocess.CompletedProcess(arguments, 2, "", "offline Homebrew failure")
        if command == ("list", "--versions", "--formula", "azure-cli"):
            return subprocess.CompletedProcess(
                arguments, 0 if self.formula else 1,
                "azure-cli " + self.formula if self.formula else "", "")
        if command == ("list", "--versions", "--cask", "azure-cli"):
            return subprocess.CompletedProcess(
                arguments, 0 if self.cask else 1,
                "azure-cli " + self.cask if self.cask else "", "")
        if command == ("uninstall", "--formula", "azure-cli"):
            self.formula = None
        elif command in (
                ("install", "--cask", "azure-cli"),
                ("upgrade", "--cask", "azure-cli"),
                ("reinstall", "--cask", "azure-cli")):
            self.cask = "current"
        elif command not in (("update",), ("fetch", "--cask", "azure-cli")):
            raise AssertionError("Unexpected Homebrew command: " + repr(command))
        return subprocess.CompletedProcess(arguments, 0, "", "")


class MacPrerequisiteTests(unittest.TestCase):
    def brew_patches(self, fixture):
        return patch.multiple(
            MODULE["shutil"], which=lambda name: BREW if name == "brew" else None,
        ), patch.object(
            MODULE["os"].path, "isfile", side_effect=lambda path: str(path) == BREW,
        ), patch.object(
            MODULE["os"], "access", side_effect=lambda path, mode: str(path) == BREW,
        ), patch.dict(MODULE, {"run": fixture.run, "log": lambda message: None})

    def install(self, fixture, home):
        which, isfile, access, functions = self.brew_patches(fixture)
        with which, isfile, access, functions:
            MODULE["brew_install"](home, "azure-cli")

    def test_legacy_versions_are_migrated_without_deleting_cache_or_extensions(self):
        for version in ("2.68.0", "2.75.0"):
            with self.subTest(version=version), tempfile.TemporaryDirectory(
                    prefix="claude-macos-migration-") as directory:
                home = Path(directory)
                cache = home / ".azure"
                extensions = cache / "cliextensions"
                extensions.mkdir(parents=True)
                (cache / "config").write_text("offline cached configuration")
                (extensions / "offline-extension").write_text("offline extension")
                fixture = HomebrewFixture(formula=version)
                self.install(fixture, home)
                self.assertEqual(fixture.calls, [
                    ("list", "--versions", "--cask", "azure-cli"),
                    ("list", "--versions", "--formula", "azure-cli"),
                    ("update",),
                    ("fetch", "--cask", "azure-cli"),
                    ("uninstall", "--formula", "azure-cli"),
                    ("install", "--cask", "azure-cli"),
                ])
                self.assertIsNone(fixture.formula)
                self.assertEqual(fixture.cask, "current")
                self.assertEqual((cache / "config").read_text(), "offline cached configuration")
                self.assertEqual((extensions / "offline-extension").read_text(), "offline extension")
                for command, options in zip(fixture.calls[2:], fixture.options[2:]):
                    self.assertFalse(options["capture"], command)
                    self.assertEqual(options["timeout"], 1800)

    def test_new_installation_selects_cask_not_formula(self):
        fixture = HomebrewFixture()
        with tempfile.TemporaryDirectory(prefix="claude-macos-new-") as directory:
            self.install(fixture, Path(directory))
        self.assertIn(("update",), fixture.calls)
        self.assertEqual(fixture.calls[-1], ("install", "--cask", "azure-cli"))
        self.assertFalse(any(command[0] in ("fetch", "uninstall") for command in fixture.calls))

    def test_existing_cask_is_upgraded(self):
        fixture = HomebrewFixture(cask="old")
        with tempfile.TemporaryDirectory(prefix="claude-macos-upgrade-") as directory:
            self.install(fixture, Path(directory))
        self.assertEqual(fixture.calls[-1], ("upgrade", "--cask", "azure-cli"))
        self.assertFalse(any(command[0] == "uninstall" for command in fixture.calls))

    def test_formula_and_cask_coexistence_reinstalls_cask_to_restore_its_launcher(self):
        fixture = HomebrewFixture(formula="2.75.0", cask="current")
        with tempfile.TemporaryDirectory(prefix="claude-macos-coexist-") as directory:
            self.install(fixture, Path(directory))
        self.assertEqual(fixture.calls[-2:], [
            ("uninstall", "--formula", "azure-cli"),
            ("reinstall", "--cask", "azure-cli"),
        ])

    def test_inspection_update_or_download_failure_leaves_formula_installed(self):
        for failure in (
                ("list", "--versions", "--cask", "azure-cli"),
                ("list", "--versions", "--formula", "azure-cli"),
                ("update",),
                ("fetch", "--cask", "azure-cli")):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(
                    prefix="claude-macos-before-removal-") as directory:
                fixture = HomebrewFixture(formula="2.75.0", fail=failure)
                with self.assertRaises(ERROR):
                    self.install(fixture, Path(directory))
                self.assertEqual(fixture.formula, "2.75.0")
                self.assertFalse(any(command[0] == "uninstall" for command in fixture.calls))

    def test_blocked_uninstall_stops_without_force_or_cask_install(self):
        fixture = HomebrewFixture(
            formula="2.75.0", fail=("uninstall", "--formula", "azure-cli"))
        with tempfile.TemporaryDirectory(prefix="claude-macos-blocked-") as directory:
            with self.assertRaises(ERROR):
                self.install(fixture, Path(directory))
        self.assertEqual(fixture.formula, "2.75.0")
        self.assertNotIn(("install", "--cask", "azure-cli"), fixture.calls)
        self.assertFalse(any("--force" in command or "--zap" in command for command in fixture.calls))

    def test_failed_replacement_reports_removed_formula_and_preserved_data(self):
        fixture = HomebrewFixture(
            formula="2.75.0", fail=("install", "--cask", "azure-cli"))
        with tempfile.TemporaryDirectory(prefix="claude-macos-replacement-") as directory:
            with self.assertRaisesRegex(ERROR, "formula was removed.*sign-in data and extensions were not deleted"):
                self.install(fixture, Path(directory))
        self.assertIsNone(fixture.formula)
        self.assertIsNone(fixture.cask)

    def test_fresh_install_failure_does_not_claim_a_formula_was_removed(self):
        fixture = HomebrewFixture(fail=("install", "--cask", "azure-cli"))
        with tempfile.TemporaryDirectory(prefix="claude-macos-fresh-failure-") as directory:
            with self.assertRaisesRegex(ERROR, "brew failed"):
                self.install(fixture, Path(directory))
        self.assertFalse(any(command[0] == "uninstall" for command in fixture.calls))

    def test_rerun_after_failed_replacement_installs_cask_without_another_uninstall(self):
        fixture = HomebrewFixture(
            formula="2.75.0", fail=("install", "--cask", "azure-cli"))
        with tempfile.TemporaryDirectory(prefix="claude-macos-retry-") as directory:
            with self.assertRaises(ERROR):
                self.install(fixture, Path(directory))
            fixture.fail = None
            self.install(fixture, Path(directory))
        self.assertEqual(fixture.cask, "current")
        self.assertEqual(fixture.calls.count(("uninstall", "--formula", "azure-cli")), 1)

    def test_cancellation_before_removal_preserves_formula(self):
        fixture = HomebrewFixture(
            formula="2.75.0", interrupt=("fetch", "--cask", "azure-cli"))
        with tempfile.TemporaryDirectory(prefix="claude-macos-cancel-") as directory:
            with self.assertRaises(KeyboardInterrupt):
                self.install(fixture, Path(directory))
        self.assertEqual(fixture.formula, "2.75.0")

    def test_cancellation_after_removal_reports_how_to_resume(self):
        fixture = HomebrewFixture(
            formula="2.75.0", interrupt=("install", "--cask", "azure-cli"))
        messages = []
        which, isfile, access, functions = self.brew_patches(fixture)
        with tempfile.TemporaryDirectory(prefix="claude-macos-cancelled-install-") as directory:
            with which, isfile, access, functions, patch.dict(MODULE, {"log": messages.append}):
                with self.assertRaises(KeyboardInterrupt):
                    MODULE["brew_install"](Path(directory), "azure-cli")
        self.assertTrue(any("interrupted after removing" in message for message in messages))

    def test_missing_homebrew_does_not_attempt_installation(self):
        with patch.object(MODULE["shutil"], "which", return_value=None), \
                patch.object(MODULE["os"].path, "isfile", return_value=False), \
                patch.dict(MODULE, {"run": lambda *args, **kwargs: self.fail("Unexpected command")}):
            with self.assertRaisesRegex(ERROR, "Homebrew will not be installed"):
                MODULE["brew_install"](Path.home(), "azure-cli")

    def test_compatible_azure_cli_is_reused_without_homebrew(self):
        with patch.dict(MODULE, {
                "find_tool": lambda *args: AZURE,
                "brew_install": lambda *args: self.fail("Compatible Azure CLI must be reused"),
        }):
            tools = MODULE["ensure_tools"](MODULE["Paths"](Path.home()), set())
        self.assertEqual(tools, {"azure": AZURE})

    def test_migration_rechecks_capability_before_returning_cli(self):
        for detected, succeeds in (([None, AZURE], True), ([None, None], False)):
            with self.subTest(succeeds=succeeds):
                with patch.dict(MODULE, {
                        "find_tool": unittest.mock.Mock(side_effect=detected),
                        "brew_install": unittest.mock.Mock(),
                }):
                    if succeeds:
                        tools = MODULE["ensure_tools"](MODULE["Paths"](Path.home()), set())
                        self.assertEqual(tools["azure"], AZURE)
                    else:
                        with self.assertRaisesRegex(ERROR, "no detected az executable supports"):
                            MODULE["ensure_tools"](MODULE["Paths"](Path.home()), set())
                    MODULE["brew_install"].assert_called_once_with(Path.home(), "azure-cli")

    def test_azure_cli_help_is_checked_on_both_output_streams(self):
        for stdout, stderr, exit_code, expected in (
                (LOGIN_FLAG, "", 0, AZURE),
                ("", LOGIN_FLAG, 0, AZURE),
                ("--allow-no-subscriptions", "", 0, None),
                (LOGIN_FLAG, "startup failure", 1, None)):
            with self.subTest(stdout=stdout, stderr=stderr, exit_code=exit_code):
                calls = []

                def run(arguments):
                    calls.append(arguments)
                    return subprocess.CompletedProcess(arguments, exit_code, stdout, stderr)

                with patch.dict(MODULE, {"tool_paths": lambda *args: [AZURE], "run": run}), \
                        patch.object(MODULE["os"].path, "isfile", return_value=True), \
                        patch.object(MODULE["os"], "access", return_value=True):
                    self.assertEqual(MODULE["find_tool"](Path.home(), "az"), expected)
                self.assertEqual(calls, [[AZURE, "login", "--help"]])

    def test_other_casks_do_not_trigger_azure_migration(self):
        calls = []

        def run(arguments, **options):
            calls.append(tuple(arguments[1:]))
            return subprocess.CompletedProcess(arguments, 1 if arguments[1] == "list" else 0, "", "")

        with patch.object(MODULE["shutil"], "which", return_value=BREW), \
                patch.object(MODULE["os"].path, "isfile", return_value=True), \
                patch.object(MODULE["os"], "access", return_value=True), \
                patch.dict(MODULE, {"run": run, "log": lambda message: None}):
            MODULE["brew_install"](Path.home(), "claude-code", cask=True)
        self.assertEqual(calls, [
            ("list", "--versions", "--cask", "claude-code"),
            ("install", "--cask", "claude-code"),
        ])


if __name__ == "__main__":
    unittest.main()
