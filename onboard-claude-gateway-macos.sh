#!/bin/bash
# Single-file macOS onboarding. Keep this file UTF-8 with LF line endings.
set -euo pipefail

if [[ "${1-}" == "--help" || "${1-}" == "-h" ]]; then
    cat <<'HELP'
Usage: bash onboard-claude-gateway-macos.sh [options]
  --client Desktop|CLI|VSCode|All       Default: prompt (Enter selects Desktop)
  --tenant-id UUID                     Customer gateway Entra tenant
  --gateway-base-url HTTPS_URL         Dedicated Azure AI Gateway Anthropic URL
  --models provider/alias[,alias...]   Full aliases; spaces between aliases also work
  --verify-models                      Opt in to one small paid request per alias

Requires macOS 14+, Apple silicon or Intel, and Python 3.11+.
Missing software uses existing IT-approved Homebrew; Homebrew is never installed.
Run in Terminal as the intended user, not with sudo or inside VS Code.
Normal setup makes no model inference requests unless --verify-models is supplied.
HELP
    exit 0
fi

fail() { printf '%s\n' "Claude gateway setup failed: $*" >&2; exit 1; }
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "This script requires macOS."
[[ "$EUID" -ne 0 ]] || fail "Run as the intended developer, not root or sudo."
version=$(/usr/bin/sw_vers -productVersion)
[[ "${version%%.*}" -ge 14 ]] || fail "macOS 14 or newer is required."
if [[ "$(/usr/bin/uname -m)" == "x86_64" ]] &&
    [[ "$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || :)" == "1" ]]; then
    fail "Open Terminal without Rosetta and rerun using native Apple silicon tools."
fi

runtime=0
case "${1-}" in --credential|--code-credential) runtime=1 ;; esac
python_path="${CLAUDE_GATEWAY_PYTHON-}"
if [[ -n "$python_path" ]]; then
    [[ "$python_path" == /* ]] || fail "The installed Python interpreter path must be absolute."
    [[ -x "$python_path" ]] || fail "The installed Python interpreter is missing. Rerun onboarding."
else
    python_from_path=$(command -v python3 || :)
    for candidate in "$python_from_path" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        if [[ "$candidate" == "/usr/bin/python3" ]] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
            continue
        fi
        if [[ -x "$candidate" ]] && "$candidate" -I -S -c 'import sys; sys.exit(not ((3,11) <= sys.version_info[:2] < (4,0)))' >/dev/null 2>&1; then
            python_path="$candidate"
            break
        fi
    done
    if [[ -z "$python_path" ]]; then
        [[ "$runtime" -eq 0 ]] || fail "Python 3.11+ is missing. Rerun onboarding."
        brew_path=""
        brew_from_path=$(command -v brew || :)
        for candidate in "$brew_from_path" /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [[ -x "$candidate" ]]; then brew_path="$candidate"; break; fi
        done
        [[ -n "$brew_path" ]] || fail "Ask IT to provide Python 3.11+ or approved Homebrew. No Homebrew installer will be run."
        printf '%s\n' "Installing Python through existing Homebrew before configuration can be validated..." >&2
        if "$brew_path" list --versions --formula python >/dev/null 2>&1; then
            "$brew_path" upgrade python >&2
        else
            "$brew_path" install python >&2
        fi
        python_path="$("$brew_path" --prefix)/bin/python3"
    fi
fi
"$python_path" -I -S -c 'import sys; sys.exit(not ((3,11) <= sys.version_info[:2] < (4,0)))' ||
    fail "Python 3.11+ is required. Ask IT to update it."
export CLAUDE_GATEWAY_BOOTSTRAP_PYTHON="$python_path"
script_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script_path="$script_dir/$(basename "${BASH_SOURCE[0]}")"
"$python_path" -I -S - "$script_path" "$@" <<'CLAUDE_GATEWAY_PYTHON'
import argparse
import base64
import contextlib
import ctypes
import hashlib
import json
import math
import os
import platform
import plistlib
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


AUDIENCE = "https://azure-api.net/aigateway"
SCOPE = AUDIENCE + "/Data.All"
MIN_CODE = (2, 1, 246)
BEHAVIOR_KEYS = {
    "disableAutoUpdates", "autoUpdaterEnforcementHours", "updateViaUpdatesHost",
    "relaunchEnforcementHours", "configRecheckIntervalMinutes",
    "egressProxyUrl", "egressProxyPacUrl",
}
PROVIDERS = {
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
}
CONFLICTS = PROVIDERS | {
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CONFIG_DIR",
}
HEADER = re.compile(r"^\s*(Authorization|api-key|x-api-key)\s*:", re.I | re.M)
SIGN_IN = re.compile(
    r"AADSTS(?:50058|50076|50079|50173|65001|70043|700082|700084|70008)\b|"
    r"interaction_required|please run[^\r\n]*az login|not logged in|"
    r"tenant[^\r\n]*not found in cloud", re.I
)


class SetupError(Exception):
    pass


def log(message):
    print(message, file=sys.stderr)


def stop_owned_command(process):
    if process.returncode is None:
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
    try:
        process.communicate(timeout=3)
    except subprocess.TimeoutExpired as error:
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
        raise SetupError("The command was stopped, but a descendant retained its output pipe. Ask IT to check the installer/tool.") from error


def run(arguments, timeout=30, capture=True, environment=None):
    command = [str(arg) for arg in arguments]
    try:
        process = subprocess.Popen(
            command, start_new_session=os.name == "posix",
            stdout=subprocess.PIPE if capture else sys.stderr,
            stderr=subprocess.PIPE if capture else sys.stderr,
            text=True, encoding="utf-8", errors="replace",
            env=environment,
        )
    except OSError as error:
        raise SetupError(f"Cannot start {arguments[0]}: {error.strerror or type(error).__name__}") from error
    try:
        output, errors = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stop_owned_command(process)
        raise SetupError(f"{Path(arguments[0]).name} timed out; no automatic retry was made.") from error
    except KeyboardInterrupt:
        stop_owned_command(process)
        raise
    return subprocess.CompletedProcess(command, process.returncode, output, errors)


def checked(arguments, timeout=30, capture=True, environment=None):
    result = run(arguments, timeout=timeout, capture=capture, environment=environment)
    if result.returncode:
        raise SetupError(
            f"{Path(arguments[0]).name} failed (exit {result.returncode}). "
            "Check the command's diagnostics or ask IT; no security controls were changed."
        )
    return result


def file_state(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise SetupError(f"Expected a regular, non-symlink configuration file: {path}")
    return path.read_bytes(), stat.S_IMODE(info.st_mode)

def exists_strict(path):
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def reject_constant(value):
    raise ValueError("Non-finite JSON constants are not supported.")


def finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("A JSON number exceeds the supported range.")
    return number


def read_json(path):
    state = file_state(path)
    if state is None:
        return {}
    data = state[0]
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    try:
        text = data.decode(encoding)
        pattern = r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/'
        text = re.sub(pattern, lambda m: m[0] if m[0].startswith('"') else
                      re.sub(r"[^\r\n]", " ", m[0]), text)
        text = re.sub(r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',
                      lambda m: m[0] if m[0].startswith('"') else "", text)
        value = json.loads(text, parse_constant=reject_constant, parse_float=finite_float) if text.strip() else {}
    except (UnicodeError, ValueError) as error:
        raise SetupError(f"Invalid JSON/JSONC settings; the original will not be replaced: {path}") from error
    if not isinstance(value, dict):
        raise SetupError(f"Settings must contain a JSON object: {path}")
    return value


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def atomic_write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def commit_files(plan, backups):
    snapshots = {path: file_state(path) for path in plan}
    changed = [path for path, (data, mode) in plan.items()
               if snapshots[path] != (data, mode)]
    for path in changed:
        if snapshots[path] is not None:
            backup = backups / (path.name + "." + str(uuid.uuid4()) + ".bak")
            atomic_write(backup, snapshots[path][0], 0o600)
    touched = []
    try:
        for path in changed:
            if file_state(path) != snapshots[path]:
                raise SetupError(f"Settings changed during setup. Close editors and retry: {path}")
            touched.append(path)
            atomic_write(path, *plan[path])
            if file_state(path) != plan[path]:
                raise SetupError(f"Saved file did not match the planned settings: {path}")
    except BaseException as error:
        failures = []
        for path in reversed(touched):
            try:
                if snapshots[path] is None:
                    if file_state(path) is not None:
                        path.unlink()
                elif file_state(path) != snapshots[path]:
                    atomic_write(path, *snapshots[path])
            except OSError:
                failures.append(str(path))
            except SetupError:
                failures.append(str(path))
        if failures:
            raise SetupError("Configuration update failed. Restore also failed for: " +
                             ", ".join(failures) + f". Ask IT to restore backups in {backups}.") from error
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise SetupError("Configuration update failed; completed writes were rolled back. " + str(error)) from error
    return len(changed)


@contextlib.contextmanager
def onboarding_lock(root):
    import fcntl
    if root.is_symlink():
        raise SetupError(f"The helper directory must not be a symlink: {root}")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = root / ".onboarding.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SetupError("Another onboarding process is running for this Mac user.") from error
        yield


class Paths:
    def __init__(self, home, system_library=Path("/Library")):
        self.home = home
        self.support = home / "Library" / "Application Support"
        self.root = self.support / "ClaudeGatewayEntra"
        self.desktop = self.support / "Claude-3p" / "configLibrary"
        self.code = home / ".claude" / "settings.json"
        self.vscode = self.support / "Code" / "User" / "settings.json"
        self.system_library = system_library


def normalize_inputs(tenant, base_url, models):
    try:
        tenant = str(uuid.UUID(tenant.strip()))
    except (ValueError, AttributeError) as error:
        raise SetupError("Provide a valid customer gateway tenant UUID.") from error
    if tenant == str(uuid.UUID(int=0)):
        raise SetupError("The tenant UUID must not be empty.")
    if not isinstance(models, (list, tuple)) or any(not isinstance(item, str) for item in models):
        raise SetupError("Models must be a list of full provider/model alias strings.")
    try:
        if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in base_url.strip()):
            raise ValueError()
        url = urllib.parse.urlsplit(base_url.strip())
        if (url.scheme != "https" or not url.hostname or
                not url.hostname.endswith(".ai.gateway.azure.com") or
                url.port not in (None, 443) or url.username is not None or
                url.password is not None or url.query or url.fragment or
                not url.path.rstrip("/").endswith("/models/anthropic")):
            raise ValueError()
        base_url = urllib.parse.urlunsplit(("https", url.hostname, url.path.rstrip("/"), "", ""))
    except (ValueError, AttributeError) as error:
        raise SetupError("Use the dedicated AI Gateway HTTPS Anthropic URL on port 443, without credentials, query, or fragment.") from error
    aliases = list(dict.fromkeys(alias.strip() for item in models for alias in item.split(",")))
    if not aliases or any(not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", alias) for alias in aliases):
        raise SetupError("Provide full provider/model aliases, not display names or empty entries.")
    return tenant, base_url, aliases


def forced_preferences(domain, candidates):
    # Check effective forced preferences as well as the documented on-disk profiles.
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    pointer = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = pointer
    cf.CFPreferencesCopyKeyList.argtypes = [pointer, pointer, pointer]
    cf.CFPreferencesCopyKeyList.restype = pointer
    cf.CFArrayGetCount.argtypes = [pointer]
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
    cf.CFArrayGetValueAtIndex.restype = pointer
    cf.CFStringGetCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetLength.argtypes = [pointer]
    cf.CFStringGetLength.restype = ctypes.c_long
    cf.CFPreferencesAppValueIsForced.argtypes = [pointer, pointer]
    cf.CFPreferencesAppValueIsForced.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [pointer]
    app = cf.CFStringCreateWithCString(None, domain.encode(), 0x08000100)
    keys = set(candidates)
    try:
        for user_name in ("kCFPreferencesCurrentUser", "kCFPreferencesAnyUser"):
            for host_name in ("kCFPreferencesAnyHost", "kCFPreferencesCurrentHost"):
                user = pointer.in_dll(cf, user_name)
                host = pointer.in_dll(cf, host_name)
                array = cf.CFPreferencesCopyKeyList(app, user, host)
                if not array:
                    continue
                try:
                    for index in range(cf.CFArrayGetCount(array)):
                        key = cf.CFArrayGetValueAtIndex(array, index)
                        buffer = ctypes.create_string_buffer(cf.CFStringGetLength(key) * 4 + 1)
                        if not cf.CFStringGetCString(key, buffer, len(buffer), 0x08000100):
                            raise SetupError("Cannot decode a managed preference key; ask IT to inspect the profile.")
                        keys.add(buffer.value.decode("utf-8"))
                finally:
                    cf.CFRelease(array)
        forced = set()
        for name in keys:
            key = cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
            try:
                if cf.CFPreferencesAppValueIsForced(key, app):
                    forced.add(name)
            finally:
                cf.CFRelease(key)
        return forced
    finally:
        cf.CFRelease(app)


def managed_keys(paths, domain, candidates):
    import pwd
    username = pwd.getpwuid(os.getuid()).pw_name
    keys = set()
    for root in (paths.system_library / "Managed Preferences",
                 paths.system_library / "Managed Preferences" / username):
        path = root / (domain + ".plist")
        state = file_state(path)
        if state is not None:
            try:
                value = plistlib.loads(state[0])
            except (plistlib.InvalidFileException, ValueError) as error:
                raise SetupError(f"Unreadable managed configuration; ask IT: {path}") from error
            if not isinstance(value, dict):
                raise SetupError(f"Managed preferences must be a dictionary: {path}")
            keys.update(value)
    return keys | forced_preferences(domain, keys | set(candidates))


def check_managed(paths, clients):
    if "Desktop" in clients:
        keys = managed_keys(paths, "com.anthropic.claudefordesktop", {
            "inferenceProvider", "inferenceGatewayBaseUrl", "inferenceCredentialKind",
            "inferenceCredentialHelper", "bootstrapUrl", "forceLoginOrgUUID",
        } | BEHAVIOR_KEYS)
        if keys - BEHAVIOR_KEYS:
            raise SetupError("Managed Claude Desktop configuration must be updated by IT; local settings will not override it.")
    if clients & {"CLI", "VSCode"}:
        directory = paths.system_library / "Application Support" / "ClaudeCode"
        managed = directory / "managed-settings.json"
        fragments = directory / "managed-settings.d"
        if exists_strict(managed) or (exists_strict(fragments) and
                                     any(item.name.endswith(".json") for item in fragments.iterdir())):
            raise SetupError("Managed Claude Code settings must be updated by IT.")
        keys = managed_keys(paths, "com.anthropic.claudecode", {
            "permissions", "env", "apiKeyHelper", "model", "availableModels",
            "forceLoginMethod", "forceLoginOrgUUID", "policyHelper", "enabledPlugins",
        })
        if keys:
            raise SetupError("Managed Claude Code preferences must be updated by IT.")


def check_environment(environment, source, aliases):
    if not isinstance(environment, dict):
        raise SetupError(f"The env setting must be a JSON object: {source}")
    for name in CONFLICTS:
        value = environment.get(name)
        disabled = name in PROVIDERS and str(value).strip().lower() in ("0", "false", "")
        if value and not disabled:
            raise SetupError(f"Conflicting {name} in {source}. Resolve it first; credentials will not be deleted.")
    headers = environment.get("ANTHROPIC_CUSTOM_HEADERS", "")
    if not isinstance(headers, str) or HEADER.search(headers):
        raise SetupError(f"Credential headers conflict with the Entra helper: {source}")
    override = environment.get("ANTHROPIC_MODEL")
    if source == "process environment" and override:
        if override not in aliases:
            raise SetupError("Conflicting ANTHROPIC_MODEL in the process environment.")
        log("An inherited ANTHROPIC_MODEL overrides the saved default and later saved /model choices.")


def desktop_meta(path):
    value = read_json(path)
    if file_state(path) is None:
        return {"appliedId": None, "entries": []}
    if ("appliedId" not in value or not isinstance(value.get("entries"), list) or
            any(not isinstance(entry, dict) or not entry.get("id") or not entry.get("name")
                for entry in value["entries"])):
        raise SetupError(f"Unsupported Desktop configuration metadata; it will not be replaced: {path}")
    return value


def vscode_environment(config):
    variables = config.get("claudeCode.environmentVariables", [])
    if not isinstance(variables, list):
        raise SetupError("VS Code Claude environment variables must be an array.")
    names = set()
    for variable in variables:
        if (not isinstance(variable, dict) or not isinstance(variable.get("name"), str) or
                not variable["name"] or not isinstance(variable.get("value"), str)):
            raise SetupError("VS Code environment entries need a name and string value.")
        if variable["name"] in names:
            raise SetupError("Resolve duplicate Claude environment names in VS Code settings before setup.")
        names.add(variable["name"])
    return variables


def build_plan(paths, settings, source, python_path, clients):
    aliases = settings["Models"]
    digest = hashlib.sha256((settings["TenantId"] + "|" + settings["GatewayBaseUrl"]).encode()).hexdigest()[:12]
    root = paths.root / digest
    config_path = root / "gateway-settings.json"
    previous = read_json(config_path)
    if file_state(config_path) is not None:
        try:
            config_id = str(uuid.UUID(previous["ConfigId"]))
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise SetupError("Existing onboarding configuration ID is invalid.") from error
        if (config_id == str(uuid.UUID(int=0)) or previous.get("TenantId") != settings["TenantId"] or
                previous.get("GatewayBaseUrl") != settings["GatewayBaseUrl"]):
            raise SetupError("Existing helper settings do not match this tenant and endpoint.")
    else:
        config_id = str(uuid.uuid4())
    settings = dict(settings, ConfigId=config_id)
    installed = root / source.name
    desktop_helper = root / "credential-helper.sh"
    code_helper = root / "code-credential-helper.sh"
    for path in (root, source, Path(python_path)):
        if any(ord(character) < 32 or ord(character) == 127 for character in str(path)):
            raise SetupError("Control characters in installation paths are not supported.")
    def wrapper(mode):
        return ("#!/bin/sh\nset -eu\nunset BASH_ENV ENV\nexport CLAUDE_GATEWAY_PYTHON=" +
                shlex.quote(str(python_path)) + "\nexec /bin/bash " +
                shlex.quote(str(installed)) + " " + mode + "\n").encode("utf-8")
    plan = {
        installed: (source.read_bytes(), 0o700),
        desktop_helper: (wrapper("--credential"), 0o700),
        code_helper: (wrapper("--code-credential"), 0o700),
        config_path: (json_bytes(settings), 0o600),
    }
    if "Desktop" in clients:
        path = paths.desktop / (config_id + ".json")
        config = read_json(path)
        headers = config.get("inferenceCustomHeaders", {})
        if not isinstance(headers, dict) or any(
                name.lower() in ("authorization", "api-key", "x-api-key") for name in headers):
            raise SetupError("Resolve credential headers in the saved Desktop configuration before onboarding.")
        config.pop("inferenceCredentialHelperArgs", None)
        config.update({
            "inferenceProvider": "gateway",
            "inferenceGatewayBaseUrl": settings["GatewayBaseUrl"],
            "inferenceGatewayAuthScheme": "bearer",
            "inferenceCredentialKind": "helper-script",
            "inferenceCredentialHelper": str(desktop_helper),
            "inferenceCredentialHelperTtlSec": 180,
            "inferenceCredentialHelperTimeoutSec": 300,
            "modelDiscoveryEnabled": False,
            "modelPrefer1mContext": False,
            "inferenceModels": [{"name": alias, "labelOverride": alias} for alias in aliases],
        })
        meta_path = paths.desktop / "_meta.json"
        meta = desktop_meta(meta_path)
        meta["entries"] = [entry for entry in meta["entries"] if entry["id"] != config_id] + [{
            "id": config_id,
            "name": "AI Gateway - Entra (" + urllib.parse.urlsplit(settings["GatewayBaseUrl"]).hostname + ")",
        }]
        meta["appliedId"] = config_id
        plan[path] = (json_bytes(config), (file_state(path) or (None, 0o600))[1])
        plan[meta_path] = (json_bytes(meta), (file_state(meta_path) or (None, 0o600))[1])
    if clients & {"CLI", "VSCode"}:
        check_environment(dict(os.environ), "process environment", aliases)
        config = read_json(paths.code)
        environment = config.setdefault("env", {})
        check_environment(environment, str(paths.code), aliases)
        environment.pop("ANTHROPIC_MODEL", None)
        gateway = {
            "ANTHROPIC_BASE_URL": settings["GatewayBaseUrl"],
            "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "180000",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": aliases[0],
            "ANTHROPIC_DEFAULT_SONNET_MODEL": aliases[0],
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": aliases[0],
        }
        environment.update(gateway)
        config.update(apiKeyHelper=shlex.quote(str(code_helper)), model=aliases[0], availableModels=aliases)
        plan[paths.code] = (json_bytes(config), (file_state(paths.code) or (None, 0o600))[1])
        if "VSCode" in clients:
            editor = read_json(paths.vscode)
            variables = vscode_environment(editor)
            check_environment({item["name"]: item["value"] for item in variables}, str(paths.vscode), aliases)
            variables = [item for item in variables if item["name"] not in gateway and item["name"] != "ANTHROPIC_MODEL"]
            variables.extend({"name": key, "value": value} for key, value in gateway.items())
            editor["claudeCode.environmentVariables"] = variables
            editor["claudeCode.disableLoginPrompt"] = True
            plan[paths.vscode] = (json_bytes(editor), (file_state(paths.vscode) or (None, 0o600))[1])
    return root, settings, plan


def version_tuple(text):
    match = re.search(r"(?m)^(\d+)\.(\d+)\.(\d+)", text)
    return tuple(map(int, match.groups())) if match else (0, 0, 0)


def app_paths(home, name):
    return [home / "Applications" / name, Path("/Applications") / name]


def find_app(home, name, bundle_id, minimum):
    for app in app_paths(home, name):
        info_path = app / "Contents" / "Info.plist"
        state = file_state(info_path)
        if state is None:
            continue
        try:
            info = plistlib.loads(state[0])
        except (plistlib.InvalidFileException, ValueError) as error:
            raise SetupError(f"Invalid application metadata: {info_path}") from error
        if not isinstance(info, dict) or info.get("CFBundleIdentifier") != bundle_id:
            raise SetupError(f"Unexpected application identity at {app}; ask IT.")
        if version_tuple(info.get("CFBundleShortVersionString", "")) >= minimum:
            return app
    return None


def tool_paths(home, name):
    return list(dict.fromkeys(filter(None, [
        shutil.which(name), str(home / ".local" / "bin" / name),
        "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name,
    ])))


def find_tool(home, name, minimum=None):
    for candidate in tool_paths(home, name):
        if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
            continue
        arguments = [candidate, "login", "--help"] if name == "az" else [candidate, "--version"]
        result = run(arguments)
        valid = "--skip-subscription-discovery" in result.stdout if name == "az" else version_tuple(result.stdout) >= minimum
        if result.returncode == 0 and valid:
            return candidate
    return None


def brew_install(home, package, cask=False, app=False):
    brew = next((path for path in (shutil.which("brew"), "/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                 if path
                 if os.path.isfile(path) and os.access(path, os.X_OK)), None)
    if not brew:
        raise SetupError(f"Missing/outdated {package}. Ask IT to install it or provide approved Homebrew. Homebrew will not be installed.")
    if package == "azure-cli" and not cask:
        cask_result = run([brew, "list", "--versions", "--cask", package])
        if cask_result.returncode not in (0, 1):
            raise SetupError("Cannot inspect the Azure CLI Homebrew cask; ask IT.")
        cask = cask_result.returncode == 0 and bool(cask_result.stdout.strip())
    kind = "--cask" if cask else "--formula"
    installed = run([brew, "list", "--versions", kind, package])
    if installed.returncode not in (0, 1):
        raise SetupError("Cannot inspect Homebrew packages; ask IT to check its installation.")
    operation = "upgrade" if installed.returncode == 0 and installed.stdout.strip() else "install"
    arguments = [brew, operation]
    if cask:
        arguments.append("--cask")
    if app and operation == "install":
        destination = home / "Applications"
        destination.mkdir(exist_ok=True)
        arguments.append("--appdir=" + str(destination))
    arguments.append(package)
    log(f"Using approved Homebrew to {operation} {package}; no force or security-bypass flags are used.")
    checked(arguments, timeout=1800, capture=False)


def ensure_extension(code):
    def installed():
        result = checked([code, "--list-extensions", "--show-versions"], timeout=120)
        match = re.search(r"^anthropic\.claude-code@(\d+\.\d+\.\d+)\s*$", result.stdout, re.M | re.I)
        return match is not None and version_tuple(match[1]) >= MIN_CODE
    if not installed():
        checked([code, "--install-extension", "anthropic.claude-code", "--force"], timeout=600, capture=False)
    if not installed():
        raise SetupError("Official Claude Code extension 2.1.246+ is missing in the default local VS Code profile.")


def ensure_tools(paths, clients):
    tools = {}
    azure = find_tool(paths.home, "az")
    if not azure:
        brew_install(paths.home, "azure-cli")
        azure = find_tool(paths.home, "az")
    if not azure:
        raise SetupError("Azure CLI still lacks tenant-only login support after installation. Ask IT.")
    tools["azure"] = azure
    for client, name, bundle, minimum, package in (
        ("Desktop", "Claude.app", "com.anthropic.claudefordesktop", (1, 8555, 0), "claude"),
        ("VSCode", "Visual Studio Code.app", "com.microsoft.VSCode", (1, 94, 0), "visual-studio-code"),
    ):
        if client in clients:
            app = find_app(paths.home, name, bundle, minimum)
            if not app:
                brew_install(paths.home, package, cask=True, app=True)
                app = find_app(paths.home, name, bundle, minimum)
            if not app:
                raise SetupError(f"{name} is missing or outdated after installation. Ask IT to check it.")
            tools[client] = app
    if "CLI" in clients:
        cli = find_tool(paths.home, "claude", MIN_CODE)
        if not cli:
            brew_install(paths.home, "claude-code", cask=True)
            cli = find_tool(paths.home, "claude", MIN_CODE)
        if not cli:
            raise SetupError("Claude Code 2.1.246+ is required after installation.")
        tools["CLI"] = cli
    if "VSCode" in clients:
        code = tools["VSCode"] / "Contents" / "Resources" / "app" / "bin" / "code"
        if not code.is_file() or not os.access(code, os.X_OK):
            raise SetupError("The detected stable VS Code app has no executable CLI.")
        ensure_extension(code)
    return tools


def running_clients(clients):
    result = checked(["/bin/ps", "-axo", "uid=,comm="])
    matches = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or parts[0] != str(os.getuid()):
            continue
        command = parts[1]
        if (("Desktop" in clients and "/Claude.app/Contents/" in command) or
                ("VSCode" in clients and "/Visual Studio Code.app/Contents/" in command) or
                ("CLI" in clients and Path(command).name == "claude" and "/Claude.app/" not in command)):
            matches.append(command)
    return matches


def wait_for_clients(clients):
    deadline = time.monotonic() + 300
    notified = False
    while running_clients(clients):
        if not notified:
            log("Save work and fully quit selected Claude clients/VS Code (Cmd+Q). Setup waits five minutes; it never kills a client.")
            notified = True
        if time.monotonic() >= deadline:
            raise SetupError("A selected client is still running. Quit it and rerun from Terminal.")
        time.sleep(2)


def validate_token(token, tenant):
    try:
        parts = token.split(".")
        if len(parts) != 3 or not all(parts):
            raise ValueError()
        encoded = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.b64decode(encoded, altchars=b"-_", validate=True).decode("utf-8"))
        if not isinstance(claims, dict):
            raise ValueError()
        if claims.get("tid") != tenant or claims.get("aud") != AUDIENCE:
            raise SetupError("The token has the wrong tenant or gateway audience.")
        if "Data.All" not in str(claims.get("scp", "")).split():
            raise SetupError("The token lacks the required delegated Data.All scope.")
        expiry = claims.get("exp")
        if isinstance(expiry, bool) or not isinstance(expiry, (int, float)) or not math.isfinite(expiry):
            raise ValueError()
        if expiry <= time.time() + 240:
            raise SetupError("The gateway token expires too soon. Rerun onboarding to sign in.")
    except (ValueError, UnicodeError, TypeError) as error:
        raise SetupError("Azure CLI did not return a valid gateway JWT.") from error
    return token


def get_token(settings, interactive=False):
    azure = settings["AzureCliPath"]
    tenant = settings["TenantId"]
    environment = dict(os.environ)
    cache = settings.get("AzureConfigDir")
    if cache is not None:
        if not isinstance(cache, str) or not os.path.isabs(cache):
            raise SetupError("The saved Azure CLI cache directory must be an absolute path; rerun onboarding.")
        environment["AZURE_CONFIG_DIR"] = cache
    for attempt in range(2):
        result = run([azure, "account", "get-access-token", "--tenant", tenant,
                      "--scope", SCOPE, "--query", "accessToken", "--output", "tsv",
                      "--only-show-errors"], timeout=45 if interactive else 15,
                     environment=environment)
        if result.returncode == 0:
            try:
                return validate_token(result.stdout.strip(), tenant)
            except SetupError as error:
                if not (interactive and attempt == 0 and "expires too soon" in str(error)):
                    raise
        elif not (interactive and attempt == 0 and SIGN_IN.search(result.stderr + result.stdout)):
            codes = ", ".join(sorted(set(re.findall(r"AADSTS\d+", result.stderr))))
            raise SetupError(f"Gateway token acquisition failed (exit {result.returncode}{', ' + codes if codes else ''}). "
                             "Rerun onboarding for sign-in; ask IT to check consent and Entra policy.")
        if interactive and attempt == 0:
            log("Complete Microsoft sign-in/MFA in the browser. No Anthropic sign-in or API key is needed.")
            checked([azure, "login", "--tenant", tenant, "--allow-no-subscriptions",
                     "--skip-subscription-discovery", "--scope", SCOPE, "--output", "none"],
                    timeout=210, capture=False, environment=environment)
    raise SetupError("No valid token was obtained after one sign-in attempt.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def verify_models(settings, token):
    opener = urllib.request.build_opener(NoRedirect())
    for alias in settings["Models"]:
        body = json_bytes({"model": alias, "max_tokens": 16,
                           "messages": [{"role": "user", "content": "Reply with exactly: OK"}]})
        request = urllib.request.Request(
            settings["GatewayBaseUrl"] + "/v1/messages", data=body, method="POST",
            headers={"Authorization": "Bearer " + token, "anthropic-version": "2023-06-01",
                     "Content-Type": "application/json"},
        )
        try:
            with opener.open(request, timeout=120) as response:
                data = response.read(1024 * 1024 + 1)
                if response.status != 200 or len(data) > 1024 * 1024:
                    raise SetupError(f"Unexpected gateway inference response for {alias}.")
                value = json.loads(data)
                if not isinstance(value, dict) or value.get("type") != "message" or not value.get("content"):
                    raise SetupError(f"Invalid gateway inference response for {alias}.")
        except urllib.error.HTTPError as error:
            raise SetupError(f"Gateway test for {alias} returned HTTP {error.code}. Check RBAC, aliases, quotas and backend access; no retry was made.") from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, UnicodeError) as error:
            raise SetupError(f"Gateway test for {alias} failed. Check connectivity, trusted certificates and the endpoint; no retry was made.") from error
        log(f"Verified bearer-only inference: {alias} (HTTP 200).")


def prompt(message):
    try:
        with open("/dev/tty", encoding="utf-8") as terminal:
            log(message)
            value = terminal.readline()
    except OSError as error:
        raise SetupError("No interactive terminal is available. Supply --client, --tenant-id, --gateway-base-url and --models.") from error
    if not value:
        raise SetupError("Input ended before configuration was supplied.")
    return value.strip()


def onboard(options, source, paths):
    selection = options.client or prompt("Choose Desktop (default), CLI, VSCode, or All:") or "Desktop"
    choices = {name.lower(): name for name in ("Desktop", "CLI", "VSCode", "All")}
    if selection.lower() not in choices:
        raise SetupError("Choose Desktop, CLI, VSCode, or All.")
    selection = choices[selection.lower()]
    clients = {"Desktop", "CLI", "VSCode"} if selection == "All" else {selection}
    tenant, base_url, aliases = normalize_inputs(
        options.tenant_id or prompt("Enter the customer gateway Directory (tenant) ID:"),
        options.gateway_base_url or prompt("Enter the customer Anthropic gateway base URL:"),
        options.models or [prompt("Enter full provider/model aliases, separated by commas:")],
    )
    if "VSCode" in clients and os.environ.get("TERM_PROGRAM") == "vscode":
        raise SetupError("Run in a separate Terminal window, not inside VS Code; selected apps must be closed.")
    python_path = os.environ.get("CLAUDE_GATEWAY_BOOTSTRAP_PYTHON", sys.executable)
    if not os.path.isabs(python_path):
        raise SetupError("The helper Python interpreter path must be absolute.")
    cache = Path(os.environ.get("AZURE_CONFIG_DIR") or str(paths.home / ".azure")).expanduser().absolute()
    settings = {"TenantId": tenant, "GatewayBaseUrl": base_url, "Models": aliases,
                "AzureCliPath": "", "AzureConfigDir": str(cache)}
    with onboarding_lock(paths.root):
        check_managed(paths, clients)
        build_plan(paths, settings, source, python_path, clients)
        wait_for_clients(clients)
        tools = ensure_tools(paths, clients)
        settings["AzureCliPath"] = str(tools["azure"])
        token = get_token(settings, interactive=True)
        if options.verify_models:
            verify_models(settings, token)
        else:
            log("Paid model tests skipped. Aliases, RBAC and inference access are unverified; use --verify-models for an intentional paid check.")
        token = None
        wait_for_clients(clients)
        check_managed(paths, clients)
        root, settings, plan = build_plan(paths, settings, source, python_path, clients)
        changed = commit_files(plan, root / "backups")
    log(f"Selected client configuration saved ({changed} files changed): {root}")
    if "CLI" in clients:
        log("Open a new Terminal in your project and run this detected supported CLI:\n" +
            shlex.quote(str(tools["CLI"])) + "\nCheck /status before sending a message.")
    if "VSCode" in clients:
        log("Reopen stable VS Code in your own trusted project. Cmd+Shift+P > Claude Code: Open in Side Bar. Workspace trust was not changed.")
    if "Desktop" in clients:
        try:
            checked(["/usr/bin/open", str(tools["Desktop"])])
        except SetupError as error:
            raise SetupError("Settings were saved, but Desktop could not be opened. Open the configured app manually.") from error
        log("Desktop launch requested. An actual conversation and Cowork readiness still require a pilot.")
    return 0


def main(arguments, source):
    parser = argparse.ArgumentParser(description="Configure native macOS Claude clients for Entra AI Gateway access.")
    parser.add_argument("--client", choices=("Desktop", "CLI", "VSCode", "All"))
    parser.add_argument("--tenant-id")
    parser.add_argument("--gateway-base-url")
    parser.add_argument("--models", nargs="+")
    parser.add_argument("--verify-models", action="store_true")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--credential", action="store_true")
    modes.add_argument("--code-credential", action="store_true")
    options = parser.parse_args(arguments)
    try:
        if platform.system() != "Darwin":
            raise SetupError("This script requires macOS.")
        if os.getuid() == 0:
            raise SetupError("Run as the intended developer, not root or sudo.")
        if platform.machine() not in ("arm64", "x86_64"):
            raise SetupError("Apple silicon or Intel x64 is required.")
        os.umask(0o077)
        if options.credential or options.code_credential:
            settings = read_json(source.parent / "gateway-settings.json")
            normalize_inputs(settings.get("TenantId"), settings.get("GatewayBaseUrl"), settings.get("Models", []))
            azure = settings.get("AzureCliPath", "")
            if not isinstance(azure, str) or not os.path.isabs(azure) or not os.path.isfile(azure) or not os.access(azure, os.X_OK):
                raise SetupError("The saved Azure CLI path is missing; rerun onboarding.")
            # Runtime helpers stay silent; fresh interactive sign-in belongs in Terminal.
            token = get_token(settings, interactive=False)
            print(token if options.code_credential else json.dumps({"token": token}, separators=(",", ":")))
            return 0
        return onboard(options, source, Paths(Path.home()))
    except (SetupError, OSError) as error:
        log("Claude gateway " + ("credential helper" if options.credential or options.code_credential else "onboarding") +
            " failed: " + str(error))
        return 1
    except KeyboardInterrupt:
        log("Onboarding cancelled. Any active configuration update attempted rollback.")
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[2:], Path(sys.argv[1]).resolve()))
CLAUDE_GATEWAY_PYTHON
