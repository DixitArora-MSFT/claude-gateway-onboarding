import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "onboard-claude-gateway-macos.sh"
EMBEDDED = SOURCE.read_text(encoding="utf-8").split("<<'CLAUDE_GATEWAY_PYTHON'\n", 1)[1]
EMBEDDED = EMBEDDED.rsplit("\nCLAUDE_GATEWAY_PYTHON", 1)[0]
MODULE = {"__name__": "onboarding_test"}
exec(compile(EMBEDDED, str(SOURCE), "exec"), MODULE)
ERROR = MODULE["SetupError"]
ROOT = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/demo/providers/Microsoft.ApiManagement/aigateways/example"
SCOPE = ROOT + "/workspaces/default"
ORIGIN = "https://example.ai.gateway.azure.com"
SETTINGS = {"TenantId": "22222222-2222-2222-2222-222222222222",
            "GatewayBaseUrl": ORIGIN + "/default/models/anthropic",
            "AzureCliPath": "az", "AzureConfigDir": str(Path.home() / ".azure")}


def alias(number, model, name=None, allowed=True, endpoint="/anthropic/v1/messages"):
    return {"id": SCOPE + f"/aliases/alias-{number}",
            "properties": {
                "aliasName": name or "provider/" + model,
                "supportedEndpoints": [endpoint],
                "backendModels": [{"resourceId": SCOPE + f"/modelProviders/provider/models/backend-{number}"}],
            }, "_model": model, "_allowed": allowed}


class CatalogFixture:
    def __init__(self, entries):
        self.entries = entries
        self.calls = []
        self.lookup = {"data": [{"id": ROOT}]}
        self.lookup_pages = {None: {"data": []}}
        self.gateways = {}
        self.host = ORIGIN
        self.page_size = len(entries) or 1

    def request(self, url, token, body=None):
        self.calls.append((url, body))
        self.assert_valid_token(token)
        if "/Microsoft.ResourceGraph/resources?" in url:
            if ORIGIN in body["query"]:
                return self.lookup
            if " | project id" not in body["query"] or "properties." in body["query"]:
                raise AssertionError("Fallback must enumerate IDs without filtering on unindexed metadata.")
            return self.lookup_pages[body["options"].get("$skipToken")]
        resource = url.removeprefix("https://management.azure.com").split("?")[0]
        if resource in self.gateways:
            response = self.gateways[resource]
            if isinstance(response, Exception):
                raise response
            return response
        if url == f"https://management.azure.com{ROOT}?api-version=2025-09-01-preview":
            return {"properties": {"frontend": {"defaultHostname": self.host.removeprefix("https://")}}}
        if "/aliases?api-version=" in url or "/aliases?next=" in url:
            offset = int(url.split("next=")[1]) if "next=" in url else 0
            page = {"value": copy.deepcopy(self.entries[offset:offset + self.page_size])}
            if offset + self.page_size < len(self.entries):
                page["nextLink"] = f"https://management.azure.com{SCOPE}/aliases?next={offset + self.page_size}"
            return page
        for entry in self.entries:
            if entry["id"] + "/providers/Microsoft.Authorization/permissions?" in url:
                return {"value": [{"actions": ["*"], "dataActions": (
                    ["Microsoft.ApiManagement/aigateways/models/*"] if entry["_allowed"] else []),
                    "notDataActions": []}]}
            if entry["properties"]["backendModels"][0]["resourceId"] + "?" in url:
                return {"properties": {"deployment": {"modelName": entry["_model"]}}}
        raise AssertionError("Unexpected catalog request: " + url)

    @staticmethod
    def assert_valid_token(token):
        if token != "offline-token":
            raise AssertionError("Unexpected token.")


class GatewayDiscoveryTests(unittest.TestCase):
    def test_runtime_url_and_full_anthropic_url_normalize_identically(self):
        for url in (ORIGIN, ORIGIN + "/", SETTINGS["GatewayBaseUrl"], SETTINGS["GatewayBaseUrl"] + "/"):
            with self.subTest(url=url):
                _, base_url, models = MODULE["normalize_inputs"](SETTINGS["TenantId"], url)
                self.assertEqual(base_url, SETTINGS["GatewayBaseUrl"])
                self.assertEqual(models, [])
        for url in ("http://example.ai.gateway.azure.com", ORIGIN + "?secret=value",
                    ORIGIN + "/unexpected", "https://example.org"):
            with self.subTest(url=url), self.assertRaises(ERROR):
                MODULE["normalize_inputs"](SETTINGS["TenantId"], url)

    def discover(self, fixture):
        with patch.dict(MODULE, {
            "run": lambda *a, **kw: subprocess.CompletedProcess([], 0, "offline-token\n", ""),
            "catalog_request": fixture.request,
        }):
            return MODULE["discover_models"](dict(SETTINGS))

    def test_exactly_one_two_or_three_models(self):
        for count in (1, 2, 3):
            entries = [alias(i, model) for i, model in enumerate(
                ("claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5")[:count])]
            with self.subTest(count=count):
                catalog = self.discover(CatalogFixture(entries))
                self.assertEqual([item["Alias"] for item in catalog],
                                 [item["properties"]["aliasName"] for item in entries])

    def test_filters_other_protocols_and_denied_aliases(self):
        entries = [
            alias(0, "claude-opus-5"),
            alias(1, "claude-sonnet-5", allowed=False),
            alias(2, "gpt-example", endpoint="/openai/v1/chat/completions"),
            alias(3, "embedding-example", endpoint="/openai/v1/embeddings"),
            alias(4, "another-vendor-model"),
        ]
        fixture = CatalogFixture(entries)
        catalog = self.discover(fixture)
        self.assertEqual([item["Alias"] for item in catalog], ["provider/claude-opus-5"])
        self.assertFalse(any("/v1/messages" in url for url, _ in fixture.calls))
        self.assertFalse(any("backend-1?" in url for url, _ in fixture.calls))

    def test_custom_alias_uses_backend_family_and_preserves_exact_spelling(self):
        catalog = self.discover(CatalogFixture([alias(0, "claude-sonnet-5", "Team-Approved")]))
        self.assertEqual(MODULE["resolve_code_model_mapping"](catalog), {"Sonnet": "Team-Approved"})

    def test_two_opus_models_do_not_invent_other_families(self):
        catalog = self.discover(CatalogFixture([alias(0, "claude-opus-4-5"), alias(1, "claude-opus-5")]))
        self.assertEqual(MODULE["resolve_code_model_mapping"](catalog), {"Opus": "provider/claude-opus-4-5"})
        self.assertEqual(len(catalog), 2)

    def test_pagination_preserves_all_models(self):
        fixture = CatalogFixture([alias(0, "claude-opus-5"), alias(1, "claude-sonnet-5")])
        fixture.page_size = 1
        self.assertEqual(len(self.discover(fixture)), 2)

    def test_empty_or_ambiguous_gateway_lookup_fails(self):
        for matches in ([], [{"id": ROOT}, {"id": ROOT + "-other"}]):
            fixture = CatalogFixture([alias(0, "claude-opus-5")])
            fixture.lookup = {"data": matches}
            with self.subTest(matches=matches), self.assertRaisesRegex(ERROR, "uniquely find"):
                self.discover(fixture)

    def test_stale_hostname_fails(self):
        fixture = CatalogFixture([alias(0, "claude-opus-5")])
        fixture.host = "https://different.ai.gateway.azure.com"
        with self.assertRaisesRegex(ERROR, "hostname"):
            self.discover(fixture)

    def unindexed_fixture(self):
        fixture = CatalogFixture([alias(0, "claude-opus-5")])
        fixture.lookup = {"data": []}
        fixture.lookup_pages = {None: {"data": [{"id": ROOT}]}}
        return fixture

    def test_unindexed_hostname_resolves_from_current_arm_metadata(self):
        fixture = self.unindexed_fixture()
        catalog = self.discover(fixture)
        self.assertEqual([item["Alias"] for item in catalog], ["provider/claude-opus-5"])
        self.assertEqual(len([url for url, _ in fixture.calls
                              if url == f"https://management.azure.com{ROOT}?api-version=2025-09-01-preview"]), 1)

    def test_indexed_hostname_does_not_enumerate_other_gateways(self):
        fixture = CatalogFixture([alias(0, "claude-opus-5")])
        self.discover(fixture)
        self.assertEqual(len([url for url, _ in fixture.calls if "/Microsoft.ResourceGraph/resources?" in url]), 1)

    def test_unindexed_hostname_resolves_when_arm_gateway_url_is_null(self):
        fixture = self.unindexed_fixture()
        fixture.gateways[ROOT] = {"properties": {
            "gatewayUrl": None,
            "frontend": {"defaultHostname": ORIGIN.removeprefix("https://")},
        }}
        self.assertEqual(len(self.discover(fixture)), 1)

    def test_unindexed_lookup_checks_every_page_and_deduplicates_resources(self):
        fixture = self.unindexed_fixture()
        other = ROOT + "-other"
        fixture.gateways[other] = {"properties": {"gatewayUrl": "https://other.ai.gateway.azure.com"}}
        fixture.lookup_pages = {
            None: {"data": [{"id": other}], "$skipToken": "second", "resultTruncated": "true"},
            "second": {"data": [{"id": other.upper()}, {"id": ROOT}]},
        }
        self.assertEqual(len(self.discover(fixture)), 1)
        self.assertEqual(len([url for url, _ in fixture.calls if url.startswith(f"https://management.azure.com{other}?")]), 1)

    def test_gateway_url_alone_accepts_case_and_trailing_slash(self):
        fixture = self.unindexed_fixture()
        fixture.gateways[ROOT] = {"properties": {"gatewayUrl": ORIGIN.upper() + "/", "frontend": None}}
        self.assertEqual(len(self.discover(fixture)), 1)

    def test_unindexed_lookup_rejects_multiple_current_hostname_matches(self):
        fixture = self.unindexed_fixture()
        other = ROOT + "-other"
        fixture.gateways[other] = {"properties": {"gatewayUrl": ORIGIN}}
        fixture.lookup_pages = {
            None: {"data": [{"id": ROOT}], "$skipToken": "second"},
            "second": {"data": [{"id": other}]},
        }
        with self.assertRaisesRegex(ERROR, "uniquely find"):
            self.discover(fixture)
        self.assertFalse(any("/aliases?" in url for url, _ in fixture.calls))

    def test_unindexed_lookup_does_not_assume_resource_name_matches_runtime(self):
        fixture = self.unindexed_fixture()
        fixture.gateways[ROOT] = {"properties": {"gatewayUrl": "https://wrong.ai.gateway.azure.com"}}
        with self.assertRaisesRegex(ERROR, "uniquely find"):
            self.discover(fixture)

    def test_unindexed_lookup_still_requires_current_hostname_metadata(self):
        for properties in ({"gatewayUrl": None, "frontend": {"defaultHostname": None}},
                           {"frontend": None}, {}):
            fixture = self.unindexed_fixture()
            fixture.gateways[ROOT] = {"properties": properties}
            with self.subTest(properties=properties), self.assertRaisesRegex(ERROR, "uniquely find"):
                self.discover(fixture)

    def test_unindexed_lookup_propagates_arm_read_failures(self):
        fixture = self.unindexed_fixture()
        fixture.gateways[ROOT] = ERROR("offline ARM read denied")
        with self.assertRaisesRegex(ERROR, "offline ARM read denied"):
            self.discover(fixture)

    def test_unindexed_lookup_rejects_invalid_ids_before_reading_them(self):
        for root in ("https://example.org", ROOT + "?redirect=other", None, 123):
            fixture = self.unindexed_fixture()
            fixture.lookup_pages = {None: {"data": [{"id": root}]}}
            with self.subTest(root=root), self.assertRaisesRegex(ERROR, "invalid gateway resource ID"):
                self.discover(fixture)
            self.assertTrue(all("/Microsoft.ResourceGraph/resources?" in url for url, _ in fixture.calls))

    def test_invalid_resource_graph_lists_fail_explicitly(self):
        for data in (None, {}, [None]):
            for fallback in (False, True):
                fixture = self.unindexed_fixture()
                if fallback:
                    fixture.lookup_pages = {None: {"data": data}}
                else:
                    fixture.lookup = {"data": data}
                with self.subTest(data=data, fallback=fallback), self.assertRaisesRegex(ERROR, "invalid gateway list"):
                    self.discover(fixture)

    def test_unindexed_lookup_rejects_repeated_or_invalid_continuation(self):
        for next_token in ("second", 123):
            fixture = self.unindexed_fixture()
            fixture.lookup_pages = {
                None: {"data": [{"id": ROOT}], "$skipToken": "second"},
                "second": {"data": [], "$skipToken": next_token},
            }
            with self.subTest(token=next_token), self.assertRaisesRegex(ERROR, "continuation token"):
                self.discover(fixture)

    def test_unindexed_lookup_cannot_accept_a_truncated_list_without_continuation(self):
        for truncated in (True, "true"):
            fixture = self.unindexed_fixture()
            fixture.lookup_pages[None]["resultTruncated"] = truncated
            with self.subTest(truncated=truncated), self.assertRaisesRegex(ERROR, "truncated"):
                self.discover(fixture)

    def test_no_permitted_models_fails_without_defaults(self):
        for entries in ([], [alias(0, "claude-opus-5", allowed=False)]):
            with self.subTest(entries=entries), self.assertRaisesRegex(ERROR, "No permitted Claude"):
                self.discover(CatalogFixture(entries))

    def test_duplicate_alias_is_rejected(self):
        entries = [alias(0, "claude-opus-5"), alias(1, "claude-opus-5")]
        with self.assertRaisesRegex(ERROR, "duplicate"):
            self.discover(CatalogFixture(entries))

    def test_unknown_backend_identity_is_rejected(self):
        fixture = CatalogFixture([alias(0, "", "provider/unknown")])
        with self.assertRaisesRegex(ERROR, "model identity"):
            self.discover(fixture)

    def test_permission_exclusions_and_additive_assignments(self):
        action = "Microsoft.ApiManagement/aigateways/models/*"
        excluded = {"dataActions": [action], "notDataActions": [action]}
        self.assertFalse(MODULE["can_invoke_model"]([excluded]))
        self.assertFalse(MODULE["can_invoke_model"]([{"actions": ["*"]}]))
        self.assertTrue(MODULE["can_invoke_model"]([excluded, {"dataActions": [action]}]))
        self.assertTrue(MODULE["can_invoke_model"]([
            {"dataActions": ["Microsoft.ApiManagement/service/workspaces/models/*"]}]))

    def test_inherited_shortcuts_cannot_add_undiscovered_models(self):
        for name in ("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
                     "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"):
            with self.subTest(name=name), self.assertRaisesRegex(ERROR, name):
                MODULE["check_environment"]({name: "other/unpublished"}, "process environment",
                                            ["provider/claude-opus-5"])

    def test_management_tokens_cannot_be_sent_to_other_origins(self):
        for url in ("https://example.org" + SCOPE + "/aliases",
                    "http://management.azure.com" + SCOPE + "/aliases"):
            with self.subTest(url=url), self.assertRaisesRegex(ERROR, "invalid Azure management URL"):
                MODULE["catalog_request"](url, "offline-token")

    def test_repeated_or_out_of_scope_pagination_is_rejected(self):
        for next_link in ("https://management.azure.com" + ROOT + "/elsewhere",
                          "https://management.azure.com" + SCOPE + "/aliases"):
            with self.subTest(next_link=next_link):
                with patch.dict(MODULE, {"catalog_request": lambda *a: {"value": [], "nextLink": next_link}}):
                    with self.assertRaisesRegex(ERROR, "pagination"):
                        list(MODULE["catalog_items"]("https://management.azure.com" + SCOPE + "/aliases", "token", SCOPE))

    def test_discovery_preserves_azure_cli_cache(self):
        fixture = CatalogFixture([alias(0, "claude-opus-5")])
        def run(arguments, **kwargs):
            self.assertEqual(kwargs["environment"]["AZURE_CONFIG_DIR"], SETTINGS["AzureConfigDir"])
            self.assertIn(SETTINGS["TenantId"], arguments)
            return subprocess.CompletedProcess(arguments, 0, "offline-token", "")
        with patch.dict(MODULE, {"run": run, "catalog_request": fixture.request}):
            MODULE["discover_models"](dict(SETTINGS))

    def test_client_plans_match_catalog_and_remove_stale_shortcuts(self):
        for count in (1, 2, 3, "two-opus"):
            names = (("claude-opus-4-5", "claude-opus-5") if count == "two-opus"
                     else ("claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5")[:count])
            catalog = self.discover(CatalogFixture([
                alias(i, model) for i, model in enumerate(names)]))
            with self.subTest(count=count), tempfile.TemporaryDirectory(prefix="claude-discovery-") as directory:
                paths = MODULE["Paths"](Path(directory))
                paths.code.parent.mkdir(parents=True)
                paths.code.write_text(json.dumps({"keepMe": True, "env": {"ANTHROPIC_DEFAULT_HAIKU_MODEL": "old/haiku"}}))
                paths.vscode.parent.mkdir(parents=True)
                paths.vscode.write_text(json.dumps({"claudeCode.environmentVariables": [
                    {"name": "ANTHROPIC_DEFAULT_HAIKU_MODEL", "value": "old/haiku"}]}))
                settings = dict(SETTINGS, Models=[item["Alias"] for item in catalog],
                                ModelMapping=MODULE["resolve_code_model_mapping"](catalog))
                with patch.dict(MODULE["os"].environ, {}, clear=True):
                    _, _, plan = MODULE["build_plan"](
                        paths, settings, SOURCE, str(Path(MODULE["sys"].executable)), {"Desktop", "CLI", "VSCode"})
                cli = json.loads(plan[paths.code][0])
                editor = json.loads(plan[paths.vscode][0])
                editor_env = {item["name"]: item["value"] for item in editor["claudeCode.environmentVariables"]}
                self.assertEqual(cli["availableModels"], settings["Models"])
                self.assertEqual(cli["model"], settings["Models"][0])
                self.assertTrue(cli["enforceAvailableModels"])
                self.assertTrue(cli["modelPicker"]["replaceBuiltInOptions"])
                self.assertEqual([row["model"] for row in cli["modelPicker"]["options"]], settings["Models"])
                self.assertTrue(cli["keepMe"])
                for family in ("Opus", "Sonnet", "Haiku"):
                    key = f"ANTHROPIC_DEFAULT_{family.upper()}_MODEL"
                    if family in settings["ModelMapping"]:
                        self.assertEqual(cli["env"][key], settings["ModelMapping"][family])
                        self.assertEqual(editor_env[key], settings["ModelMapping"][family])
                    else:
                        self.assertNotIn(key, cli["env"])
                        self.assertNotIn(key, editor_env)
                profile = next(data for path, (data, _) in plan.items()
                               if path.parent == paths.desktop and path.name != "_meta.json")
                self.assertEqual([item["name"] for item in json.loads(profile)["inferenceModels"]], settings["Models"])

    def test_existing_direct_foundry_mode_is_switched_off_in_selected_user_settings(self):
        settings = dict(SETTINGS, Models=["provider/claude-opus-5"],
                        ModelMapping={"Opus": "provider/claude-opus-5"})
        for clients in ({"CLI"}, {"VSCode"}, {"CLI", "VSCode"}):
            for value in ("1", "true", True, "0", "false", False):
                with self.subTest(clients=clients, value=value), tempfile.TemporaryDirectory(
                        prefix="claude-foundry-switch-") as directory:
                    paths = MODULE["Paths"](Path(directory))
                    paths.code.parent.mkdir(parents=True)
                    paths.vscode.parent.mkdir(parents=True)
                    original_code = json.dumps({
                        "keepMe": True, "env": {"CLAUDE_CODE_USE_FOUNDRY": value, "KEEP_ME": "unchanged"},
                    })
                    original_editor = json.dumps({
                        "editor.fontSize": 16, "claudeCode.environmentVariables": [
                            {"name": "CLAUDE_CODE_USE_FOUNDRY", "value": str(value)},
                            {"name": "KEEP_ME", "value": "unchanged"},
                        ],
                    })
                    paths.code.write_text(original_code)
                    paths.vscode.write_text(original_editor)
                    with patch.dict(MODULE["os"].environ, {}, clear=True):
                        _, _, plan = MODULE["build_plan"](
                            paths, settings, SOURCE, MODULE["sys"].executable, clients)
                    config = json.loads(plan[paths.code][0])
                    self.assertEqual(config["env"]["CLAUDE_CODE_USE_FOUNDRY"], "0")
                    self.assertEqual(config["env"]["KEEP_ME"], "unchanged")
                    self.assertTrue(config["keepMe"])
                    self.assertEqual(config["env"]["ANTHROPIC_BASE_URL"], settings["GatewayBaseUrl"])
                    if "VSCode" in clients:
                        editor = json.loads(plan[paths.vscode][0])
                        variables = editor["claudeCode.environmentVariables"]
                        switches = [item for item in variables if item["name"] == "CLAUDE_CODE_USE_FOUNDRY"]
                        self.assertEqual(switches, [{"name": "CLAUDE_CODE_USE_FOUNDRY", "value": "0"}])
                        self.assertEqual(editor["editor.fontSize"], 16)
                        self.assertIn({"name": "KEEP_ME", "value": "unchanged"}, variables)
                    else:
                        self.assertNotIn(paths.vscode, plan)
                    self.assertEqual(paths.code.read_text(), original_code)
                    self.assertEqual(paths.vscode.read_text(), original_editor)

    def test_automatic_foundry_switch_does_not_allow_other_provider_or_credential_conflicts(self):
        for name in MODULE["CONFLICTS"] - {"CLAUDE_CODE_USE_FOUNDRY"}:
            with self.subTest(name=name), self.assertRaisesRegex(ERROR, name):
                MODULE["check_environment"](
                    {"CLAUDE_CODE_USE_FOUNDRY": "1", name: "offline-conflict"},
                    "user settings", [], allow_foundry_switch=True)
        with self.assertRaisesRegex(ERROR, "Credential headers"):
            MODULE["check_environment"](
                {"CLAUDE_CODE_USE_FOUNDRY": "1", "ANTHROPIC_CUSTOM_HEADERS": "Authorization: offline-conflict"},
                "user settings", [], allow_foundry_switch=True)

    def test_direct_foundry_mode_in_process_environment_still_stops_setup(self):
        settings = dict(SETTINGS, Models=["provider/claude-opus-5"],
                        ModelMapping={"Opus": "provider/claude-opus-5"})
        with tempfile.TemporaryDirectory(prefix="claude-foundry-env-") as directory:
            paths = MODULE["Paths"](Path(directory))
            with patch.dict(MODULE["os"].environ, {"CLAUDE_CODE_USE_FOUNDRY": "1"}, clear=True):
                with self.assertRaisesRegex(ERROR, "CLAUDE_CODE_USE_FOUNDRY in process environment"):
                    MODULE["build_plan"](paths, settings, SOURCE, MODULE["sys"].executable, {"CLI"})
                self.assertEqual(MODULE["os"].environ["CLAUDE_CODE_USE_FOUNDRY"], "1")
            self.assertFalse(paths.code.exists())

    def test_desktop_only_leaves_direct_foundry_code_settings_untouched(self):
        settings = dict(SETTINGS, Models=["provider/claude-opus-5"],
                        ModelMapping={"Opus": "provider/claude-opus-5"})
        with tempfile.TemporaryDirectory(prefix="claude-foundry-desktop-") as directory:
            paths = MODULE["Paths"](Path(directory))
            paths.code.parent.mkdir(parents=True)
            original = '{"env":{"CLAUDE_CODE_USE_FOUNDRY":"1"}}'
            paths.code.write_text(original)
            with patch.dict(MODULE["os"].environ, {}, clear=True):
                _, _, plan = MODULE["build_plan"](
                    paths, settings, SOURCE, MODULE["sys"].executable, {"Desktop"})
            self.assertNotIn(paths.code, plan)
            self.assertNotIn(paths.vscode, plan)
            self.assertEqual(paths.code.read_text(), original)


if __name__ == "__main__":
    unittest.main()
