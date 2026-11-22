# Chocolatey package

Users install Glasspen Meet with:

```powershell
choco install glasspen-meet
```

The package doesn't contain the app. Its install script downloads `GlasspenMeet.exe` from the GitHub
release and checks its SHA-256, then adds a Start menu shortcut and a `GlasspenMeet` command.

## Publish a new version

1. Build the exe (`dotnet publish src\Glasspen.Windows -c Release -o publish` in `windows/`) and upload it
   to a new GitHub release.
2. In `tools/chocolateyinstall.ps1`, set `$url64` to the new download link and `$checksum64` to
   `(Get-FileHash publish\GlasspenMeet.exe -Algorithm SHA256).Hash`.
3. In `glasspen-meet.nuspec`, set `<version>` and `<releaseNotes>`.
4. Pack and test in an **administrator** PowerShell, from this folder:

   ```powershell
   choco pack
   choco install glasspen-meet -s . -y --force
   choco uninstall glasspen-meet -y
   ```

5. Push it (the API key is at <https://community.chocolatey.org/account>):

   ```powershell
   choco apikey add -s https://push.chocolatey.org/ -k <your-api-key>
   choco push glasspen-meet.<version>.nupkg -s https://push.chocolatey.org/
   ```

New versions go through Chocolatey's automatic checks and then a human moderator, which can take a few
days for a first package. Until it's approved, `choco install glasspen-meet` can't find it.
