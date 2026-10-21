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
   User** access at the appropriate gateway or model scope.
4. Resolve required consent, MFA, Conditional Access, and device-compliance
   requirements for Azure CLI's delegated
   `https://azure-api.net/aigateway/Data.All` scope.
5. Allow the gateway, identity endpoints, and approved software sources through
   network controls, and approve script execution and application installation.
6. Provide the **tenant ID**, **gateway Anthropic base URL**, and **full published
   model aliases** to users, or supply them in a completed launch command.

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

If you saved the file elsewhere, adjust the path.

For either script:

1. Select `Desktop`, `CLI`, `VSCode`, or `All`. Press Enter for Desktop.
2. Enter the tenant ID, gateway URL, and exact model aliases provided by IT.
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
| Full model aliases | `-Models` | `--models` |

Both scripts accept a quoted comma-separated list of aliases. Use the complete
published aliases, not an assumed model name.

## What setup does

- Installs or updates missing/incompatible prerequisites and the selected
  applications through the approved package manager: WinGet on Windows,
  existing Homebrew on macOS.
- Installs the official `anthropic.claude-code` extension when VS Code is selected.
  VS Code-only setup does not install the standalone Claude Code CLI.
- Creates local credential helpers using delegated Microsoft Entra tokens.
- For Desktop, saves and selects the Gateway profile, Helper script credential
  kind, Bearer scheme, gateway URL, helper path, and model list automatically.
- Configures the corresponding user settings for CLI and VS Code when selected.
- Preserves unrelated settings, creates backups of replaced configuration, and
  attempts rollback after reported configuration-update failures.
- Stops for incompatible managed settings or conflicting credentials instead of
  overriding organizational controls.

Users do not need to fill in the Desktop connection screen manually. They still
need to run setup, complete Microsoft sign-in/MFA, and approve normal installation
prompts. Windows can require a restart; none is forced.

## References

- [Microsoft: AI Gateway tier overview and preview limitations](https://learn.microsoft.com/en-us/azure/api-management/ai-gateway-overview)
- [AI Gateway: security and identity](https://ai.gateway.azure.com/docs/security-identity)
- [Anthropic: Claude Desktop installation and device requirements](https://claude.com/docs/third-party/claude-desktop/installation)
- [Anthropic: Claude Code in VS Code](https://code.claude.com/docs/en/vs-code)

These references also describe other connection methods. For these scripts,
retain the supplied Gateway/Bearer/helper-script configuration rather than
substituting an API-key setup.
