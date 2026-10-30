# Claude Gateway Onboarding

Single-file Windows and macOS setup for Claude Desktop, Claude Code CLI, and the
official Claude Code VS Code extension, using Microsoft Foundry through the
dedicated Azure AI Gateway with Microsoft Entra authentication.

No customer API keys, passwords, access tokens, tenant IDs, or gateway addresses
are included. Your administrator supplies the connection details.

> **Pilot status:** The macOS script has offline regression coverage but has not
> yet been validated on real Apple silicon or Intel Macs. Complete representative
> device and application pilots before customer rollout. AI Gateway tier is in
> public preview. Neither script guarantees zero failures on every device.

## Customer onboarding guide

[Download the customer onboarding guide (Word)](docs/AI-Gateway-Customer-Onboarding-Guide.docx).
Open the file and choose **Download raw file** to save it.

The guide covers administrator preparation, where to find the connection details,
and setup steps for users. Customer-specific values are placeholders; IT supplies
the approved configuration. Personal editor metadata has been removed from this
published copy.

## Choose your script

| Platform | Download | Requirements |
| --- | --- | --- |
| Windows | [onboard-claude-gateway.ps1](onboard-claude-gateway.ps1) | Windows build 19041+, x64/ARM64, 64-bit Windows PowerShell 5.1 |
| macOS | [onboard-claude-gateway-macos.sh](onboard-claude-gateway-macos.sh) | macOS 14+, Apple silicon or Intel x64, Python 3.11+ |

Open the appropriate file above and use **Download raw file**. Keep its original
filename. For macOS, preserve LF line endings.

## Before running

Your Azure/IT administrator must:

1. Publish the intended Foundry Claude models through the dedicated AI Gateway.
2. Configure and authorize the gateway's backend managed identity.
3. Grant approved users, preferably through an Entra group, **AI Gateway Models
   User** access at the appropriate gateway or model scope. For automatic model
   discovery, also grant **Reader** on this gateway (or equivalent scoped catalog
   and effective-permission read access). Reader does not grant model invocation.
4. Resolve required consent, MFA, Conditional Access, and device-compliance
   requirements for Azure CLI's delegated
   `https://azure-api.net/aigateway/Data.All` scope.
5. Allow the gateway, identity endpoints, and approved software sources through
   network controls, and approve script execution and application installation.
6. Provide the **tenant ID** and **gateway runtime URL** to users, or supply
   them in a completed launch command. Developers do not enter model aliases,
   shortcut mappings, subscription IDs, or gateway resource IDs.

The scripts do not create Azure resources, deploy models, grant permissions, or
bypass IT policies. This integration uses the dedicated public-Azure AI Gateway
Anthropic endpoint, not arbitrary proxy URLs or direct Foundry API-key setup.

## Run the setup

Save the appropriate script in your Downloads folder. Run as the normal user who
will use Claude, not as another administrator account. Save work and fully quit
selected applications when prompted.

### Windows

Open **Windows PowerShell** from Start, not PowerShell 7 or VS Code's integrated
terminal:

```powershell
powershell.exe -NoProfile -File "$env:USERPROFILE\Downloads\onboard-claude-gateway.ps1"
```

### macOS

Open **Terminal**, not VS Code's integrated terminal. Do not run with `sudo` or
under Rosetta:

```bash
bash "$HOME/Downloads/onboard-claude-gateway-macos.sh"
```

Compatible Azure CLI installations are reused. If Azure CLI is missing or lacks
the required tenant-only login option, setup installs or updates the current
Homebrew cask. An older Homebrew formula is migrated automatically: setup
refreshes Homebrew metadata and downloads the cask before removing the formula.
It preserves the Azure CLI sign-in cache and extensions; no manual migration
commands are required. If replacement installation fails after formula removal,
setup stops with diagnostics; rerun onboarding to finish installation. Software
installation changes are not part of client-configuration rollback.

If you saved the file elsewhere, adjust the path.

For either script:

1. Select `Desktop`, `CLI`, `VSCode`, or `All`. Press Enter for Desktop.
2. Enter the tenant ID and gateway URL provided by your administrator.
3. Complete Microsoft sign-in/MFA if requested.
4. Follow installation approvals, app-close instructions, and any Windows
   restart/rerun instructions.

IT can supply the connection values as command parameters so users do not have
to enter technical details. The parameters are:

| Setting | Windows | macOS |
| --- | --- | --- |
| Client | `-Client` | `--client` |
| Tenant ID | `-TenantId` | `--tenant-id` |
| Gateway URL | `-GatewayBaseUrl` | `--gateway-base-url` |

The previous `-Models` / `--models` arguments have been removed. The gateway is
the source of truth for the model list.

Copy the **Gateway runtime endpoint** from AI Gateway Home. Both scripts
automatically append `/default/models/anthropic`. A full Anthropic base URL
continues to work. No developer needs to construct the endpoint path.

### Automatic model discovery

After work-account sign-in, both scripts find the gateway from its runtime
hostname using Azure Resource Graph. If Resource Graph does not index the
hostname fields, they enumerate accessible gateway resource IDs across all result
pages and check current Azure Resource Manager metadata for an exact hostname
match. They stop if no unique gateway matches; resource names are never guessed
from the URL. This fallback does not require developers to enter resource IDs or
grant additional permissions. They read its published aliases, check the
signed-in user's model-invocation permissions, and read backend model metadata.
Only permitted Claude aliases supporting Anthropic Messages are configured;
OpenAI, DeepSeek, embeddings, and other incompatible models are excluded.

There is no customer gateway name, model alias, version, or model-count limit
hardcoded in the scripts. A gateway exposing one, two, or three permitted Claude
aliases produces exactly that list in Desktop, CLI, and VS Code. Custom callable
aliases are preserved exactly. Claude Code shortcuts are mapped from the actual
backend model family, not from guesses about the alias name. Missing families
are not invented or redirected to a different family. The first discovered alias
is the default; every discovered alias gets its own Claude Code picker entry,
including multiple aliases from the same family. Built-in model rows are replaced;
the client can still display its Default and current-model rows.

Discovery uses read-only Azure management APIs and does not send inference
requests or change gateway permissions. It requires catalog read access in
addition to the runtime role. If discovery fails or no permitted Claude aliases
are found, setup stops without guessing a model or writing client configuration.
Azure Resource Graph and RBAC updates can take time to propagate.

Rerun onboarding after changing published models or group access to refresh
the local model list. Gateway authorization always remains the final authority;
discovery does not prove that an inference request will pass network, quota, or
other gateway/backend policies. Use `-VerifyModels` / `--verify-models` only when
you intentionally want a small paid inference check for every discovered alias.

## What the setup does for you

- Checks for required software and installs or updates it where your IT policies
  allow.
- Sets up the Claude application or applications you choose.
- Saves your company's connection details and approved model list, so you do not
  need to fill in the Claude Desktop settings yourself.
- Keeps unrelated settings and backs up existing files before changing them.
- Automatically switches existing direct Foundry mode to gateway mode for CLI
  and VS Code by saving `CLAUDE_CODE_USE_FOUNDRY=0` in the selected user settings,
  and displays a message. The previous settings are backed up; credentials are
  not deleted. Desktop-only setup does not change Claude Code settings.
- Stops and asks for IT assistance for other conflicting credentials/provider
  settings, enabled provider switches in the environment, or company policies.
  Environment variables and managed policies are not changed.

**What you need to do:** Run the command supplied by IT, sign in with your work
account if prompted, and complete any required approval or verification steps.
Follow the instructions to close or reopen applications. If Windows needs a
restart, the script will tell you; it will not restart your computer automatically.

## References

- [Microsoft: AI Gateway tier overview and preview limitations](https://learn.microsoft.com/en-us/azure/api-management/ai-gateway-overview)
- [AI Gateway: security and identity](https://ai.gateway.azure.com/docs/security-identity)
- [Anthropic: Claude Desktop installation and device requirements](https://claude.com/docs/third-party/claude-desktop/installation)
- [Anthropic: Claude Code in VS Code](https://code.claude.com/docs/en/vs-code)

These references also describe other connection methods. For these scripts,
retain the supplied Gateway/Bearer/helper-script configuration rather than
substituting an API-key setup.
