Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class GitPusher4 {
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
    public static extern void CredFree(IntPtr cred);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static string GetUtf8(string target) {
        IntPtr credPtr;
        if (CredRead(target, 1, 0, out credPtr)) {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
            byte[] bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
            CredFree(credPtr);
            return Encoding.UTF8.GetString(bytes);
        }
        return null;
    }
}
"@

$tok = [GitPusher4]::GetUtf8("GitHub - https://api.github.com/IDhexter")
if (-not $tok) {
    Write-Error "Could not retrieve GitHub Desktop OAuth token from Windows Credential Manager."
    exit 1
}

$git = "C:\Users\alexs\AppData\Local\GitHubDesktop\app-3.6.7\resources\app\git\cmd\git.exe"

Write-Output "--- Resetting History to 1 Clean Commit ---"
& $git checkout --orphan clean-main
& $git reset

Write-Output "--- Staging Clean Files ---"
& $git add .env.example
& $git add .gitignore
& $git add LICENSE
& $git add README.md
& $git add assets/aruba_switch_dashboard.png
& $git add assets/port_selection_click.png
& $git add grafana/dashboards/aruba_instant_on_1930.json
& $git add grafana/dashboards/aruba_interactive_twin.html
& $git add scripts/build_aruba_interactive_twin.ps1
& $git add scripts/export_sanitized_dashboard.ps1
& $git add scripts/direct_grafana_shot.ps1
& $git add scripts/git_commit_and_push.ps1
& $git add .ia/ARCHITECTURE.md
& $git add .ia/MEMORY.md
& $git add .ia/RULES.md
& $git add .ia/RUNBOOK.md
& $git add .ia/TASKS.md

Write-Output "--- Committing Initial Clean Version ---"
& $git commit -m "feat: Aruba Instant On 1930 24G 4SFP+ Digital Twin for Grafana & Zabbix"

Write-Output "--- Replacing Branch main ---"
& $git branch -D main
& $git branch -m main

Write-Output "--- Force Pushing to GitHub (Purging Previous History) ---"
$url = "https://${tok}@github.com/IDhexter/Grafana-Switch.git"
& $git push --force $url main:main 2>&1
& $git update-ref refs/remotes/origin/main HEAD

Write-Output "--- GitHub History Reset Completed ---"
& $git status
& $git log --oneline
