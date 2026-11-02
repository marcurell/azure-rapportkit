# Azure Rapportkit

A PowerShell script that produces the material for a review of your Azure environment. It runs **on a computer at your site, with your account**, fetches a few well-known analysis tools (Azure Governance Visualizer, azqr and, if you wish, Maester), reads Defender, Secure Score, cost, management groups and networks, and summarises everything in a multi-page report.

- The script **writes nothing to your Azure resources** or to Entra ID. It makes read calls only.
- The result is saved **locally** in a folder you choose. The script sends nothing anywhere.
- What happens, what data ends up in the result and what is changed on the computer is described in [docs/KUNDINFO.md](docs/KUNDINFO.md). A short step-by-step guide is in `docs\Azure-Rapportkit-Customer-guide.docx`.

## Before you start

| Needed | Comment |
|---|---|
| A Windows computer with internet | Windows 10 or 11, about 2 GB free. Open to github.com, powershellgallery.com, login.microsoftonline.com, management.azure.com and graph.microsoft.com. The script checks this first |
| An account with the right roles | On the **Tenant Root Group**: Reader, Security Reader and Cost Management Reader. For the Entra tests (Maester): Global Reader. If you use PIM: activate the roles first. The script checks the roles right after sign-in and shows how to add them |
| Tenant ID | Entra ID > Overview > Tenant ID |
| A heads-up to the security team | The run makes many read calls and signs in from the computer. Please tell the SOC / operations security in advance |
| Administrator approval (if Azure CLI is missing) | Azure CLI is installed by the script and then asks for administrator approval (UAC) |
| Admin consent for Maester (optional) | A Global Administrator needs to approve read permissions for *Microsoft Graph Command Line Tools* the first time. Skip Maester with `-SkipMaester` if this does not suit |

## Start

1. **Unblock the zip file:** right-click the zip file you received, choose **Properties**, tick **Unblock** (if the box exists) and click OK. Windows otherwise blocks scripts that arrive by e-mail.
2. **Unpack:** right-click the zip file and choose **Extract All**.
3. **Open PowerShell** (not ISE) in the unpacked folder: hold Shift, right-click in the folder and choose *Open PowerShell window here*, or open PowerShell and go there with `cd`.
4. **Run:**

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Run-Rapportkit.ps1
```

Windows PowerShell 5.1 is enough: the script installs PowerShell 7 if needed and continues there. The run normally takes 10 to 30 minutes depending on the size of the environment.

## During the run

The script shows a box per step (`STEP 3 OF 10`) and describes what is happening. The messages in the window are in English. It asks for:

- **Tenant ID** (a suggestion is shown if you are already signed in).
- **Where the result is saved.** Avoid OneDrive folders and folders that sync to the cloud: the result is confidential.
- **Whether the result is encrypted with a password.** Answer **y** (yes) if the file is to be sent on. You choose a password of at least 12 characters (typed twice). Write it down: it cannot be recovered.
- **Whether an anonymized version of the report is created** (for demos or sharing). Normally: no.
- **Sign-in** in the browser (Azure CLI, Azure PowerShell and, if Maester is run, Microsoft Graph).

If a role or something else important is missing you are told right away and choose whether to continue anyway. The script can be stopped with Ctrl+C and run again: what is already done is reused.

## When it is done

The result is in `<result folder>\<year-month>\`. Open `rapport.html` to look at it. The report has seven pages: Overview, Structure, Governance, Resources, Entra ID, Defender & cost and About the run. The button **Save the whole report as PDF** collects all the pages. The report text is in the language the kit was prepared for (set with `-ReportLanguage`, for example `-ReportLanguage sv`).

**Send the result to us:**

1. Send the file `rapportkit_<tenant>_<year-month>.zip.rkenc` (and preferably the `.sha256` file next to it) by e-mail or the channel you have agreed on.
2. Send the **password by another route**, for example by SMS or phone. Never send the password in the same message as the file.
3. Delete the result folder from the computer when the assignment is done. It contains unencrypted copies.

The script signs out of the sign-ins it created itself when it is done.

## If something goes wrong

- The script writes what happened, what you should do and exactly which command to run again. A tool that fails does not stop the others: the report shows what went well.
- If needed, send `rapportkit.log` from the result folder. It contains no passwords or tokens, but the tenant ID and names of accounts and resources may appear.

| Problem | Action |
|---|---|
| The script is blocked | Unblock the zip file before unpacking (step 1 above), or run `Get-ChildItem -Recurse \| Unblock-File` in the folder |
| Roles are missing | Follow the instruction that is shown, or ask a Global Administrator to elevate access and assign the roles |
| Maester requires approval | Ask a Global Administrator to approve, or run with `-SkipMaester` |
| Download fails | Check the proxy and firewall (see the list of addresses above) |
| Antivirus/EDR blocks azqr | Ask IT to allow the file `azqr.exe` in the result folder |
| `429 Too Many Requests` in the log | Normal with many calls. The tools try again automatically |

## Switches (optional)

| Switch | Meaning |
|---|---|
| `-TenantId <guid>` | Skips the tenant question |
| `-OutputRoot <folder>` | Where the result is saved |
| `-SkipMaester` / `-SkipGovViz` / `-SkipAzqr` | Skip a tool |
| `-DeviceLogin` | Sign in with a code instead of a browser window |
| `-HidePersonalData` | Hide names and e-mail in Governance Visualizer's report |
| `-Anonymize` | Also create an anonymized report in the folder `anonym` |
| `-ReportLanguage <code>` | Language of the report text (`en` or `sv`) |
| `-NoEncrypt` | Do not encrypt the result package (only if it does not leave the computer) |
| `-KeepLogin` | Do not sign out after the run |

## Licence and third-party tools

The kit is included as MIT-licensed software, see `LICENSE`. The tools that the script fetches have their own licences, see `THIRD-PARTY-NOTICES.md`. The kit is provided without warranty, and the report is material for an assessment that does not replace a review by a qualified person.
