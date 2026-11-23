# Building EUnifyer Office for Windows (x64)

This is the reproducible recipe for producing the Windows `.zip` that ships in
[`EUnifyer/eunify-office-dist`](https://github.com/EUnifyer/eunify-office-dist).
It was first done on a temporary Azure VM (built `v26.8.0.0`).

> **Why Windows is the hard one.** macOS and Linux are *native Unix* builds, so
> `scripts/build.sh` runs almost clean. Windows has no native Unix shell:
> LibreOffice needs **Cygwin** to run `autogen.sh`/`make`, but the compiler is
> **native MSVC (`cl.exe`)**. Every tool then sits on the Cygwin↔Windows seam
> (paths `/cygdrive/c` vs `C:\`, separators `:` vs `;`, pthread vs Win threads,
> shebang exec bits, temp dirs). The single biggest lesson below is: **drive the
> meson-based externals (harfbuzz) with a *native* Windows meson/ninja/pkgconf**,
> not the Cygwin ones. That removes the whole class of seam problems.

GitHub-hosted runners can't do this build (6h job cap, disk), so use a beefy
x64 VM. The build is ~50 min compile on 16 cores after the toolchain is set up.

---

## 1. Provision a build VM (Azure example)

```bash
RG=eunify-office-winbuild; REGION=eastus
ssh-keygen -t ed25519 -f ~/.ssh/lo-winbuilder -N "" -q
PW="Eu$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)!9"   # save this
az group create -n $RG -l $REGION --tags purpose=temp-win-build teardown=yes -o none
az vm create -g $RG -n win-builder \
  --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest \
  --size Standard_D16as_v5 --admin-username azureadmin --admin-password "$PW" \
  --os-disk-size-gb 256 --storage-sku Premium_LRS --public-ip-sku Standard --nsg-rule RDP
```

D16as_v5 = 16 vCPU / 64 GB. 256 GB disk (VS + Cygwin + ~40 GB build tree).
**Tear it all down when done:** `az group delete -n eunify-office-winbuild --yes`.

### Enable OpenSSH + open the NSG

Run once via `az vm run-command invoke ... RunPowerShellScript`:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force
Set-Content 'C:\ProgramData\ssh\administrators_authorized_keys' -Value '<your pubkey>' -Encoding ascii
icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
```
Then: `az network nsg rule create -g $RG --nsg-name win-builderNSG -n AllowSSH --priority 1001 --protocol Tcp --destination-port-ranges 22 --access Allow --direction Inbound`

Also extend `C:` to the full disk: `Resize-Partition -DriveLetter C -Size (Get-PartitionSupportedSize -DriveLetter C).SizeMax`.

> **Long installs/builds over SSH:** run them as a **SYSTEM Scheduled Task**
> (`schtasks /create ... /ru SYSTEM /rl HIGHEST`, then `schtasks /run`) writing a
> marker file on completion, and poll. Detached `Start-Process` and `Start-Job`
> don't survive the SSH session reliably; scheduled tasks do.

---

## 2. Toolchain

All via Chocolatey (`Set-ExecutionPolicy Bypass -Scope Process -Force; iex (...community.chocolatey.org/install.ps1)`):

1. **VS 2022 C++ Build Tools** — use the official bootstrapper (the choco
   `visualstudio2022buildtools` package hung; the bootstrapper is reliable):
   ```
   curl -LO https://aka.ms/vs/17/release/vs_BuildTools.exe
   vs_BuildTools.exe --quiet --wait --norestart \
     --add Microsoft.VisualStudio.Workload.VCTools \
     --add Microsoft.VisualStudio.Component.Windows11SDK.22621 \
     --add Microsoft.VisualStudio.Component.VC.ATL \
     --includeRecommended
   ```
   **ATL is required** (the ActiveX module needs `atlbase.h`).
2. **LLVM/clang** — `choco install -y llvm` (LO's configure needs `clang-cl` for
   skia; it searches `C:\Program Files\LLVM\bin\clang-cl.exe`).
3. **Cygwin + packages**:
   ```
   curl -LO https://www.cygwin.com/setup-x86_64.exe
   setup-x86_64.exe -q -n -N -d -B -R C:\cygwin64 -s http://mirrors.kernel.org/sourceware/cygwin/ -l C:\cygwin64\packages \
     -P autoconf,automake,bison,flex,gcc-g++,gdb,git,gnupg2,gperf,make,nasm,openssl,perl,perl-Archive-Zip,pkg-config,python3,python39,unzip,wget,zip,zstd,m4,patch,diffutils,findutils,file,dos2unix,meson,ninja
   ```
4. **Native Windows toolchain** for the meson externals (the key bit):
   ```
   choco install -y python313                       # native Windows Python
   C:\Python313\python.exe -m pip install meson ninja
   ```
   Native meson lands in `C:\Python313\Scripts\meson.exe`, native ninja too.

### Build a native pkgconf

The Cygwin pkgconf uses `:`-separated POSIX paths; native meson wants `;` Windows
paths — they don't mix. Build a native one with native meson + cl (inside a
Cygwin shell with `vcvars64` env imported — `INCLUDE`/`LIB`/`PATH`):

```bash
tar -xf .../tarballs/pkgconf-2.4.3.tar.xz -C /cygdrive/c/pkgconf-build   # or download from dev-www.libreoffice.org/src/
cd /cygdrive/c/pkgconf-build/pkgconf-2.4.3
export CC=cl CXX=cl
/cygdrive/c/Python313/Scripts/meson.exe setup _bn --buildtype=release -Dtests=disabled
/cygdrive/c/Python313/Scripts/ninja.exe -C _bn pkgconf.exe
mkdir -p /cygdrive/c/nativetools
cp _bn/pkgconf.exe _bn/pkgconf-6.dll /cygdrive/c/nativetools/   # .dll must sit next to the .exe
cp /cygdrive/c/Python313/Scripts/ninja.exe /cygdrive/c/nativetools/
```

`/cygdrive/c/nativetools/` now holds native `pkgconf.exe` (+ its dll) and `ninja.exe`.

---

## 3. `build.sh` flags (already committed)

`scripts/build.sh` applies these Windows-only (`uname -s` = `CYGWIN*`) automatically:

- `--disable-cli` — skips the .NET/CLI UNO bindings (need `al.exe`); end users don't need them.
- `--disable-gpgmepp` — the gpg externals (`libgpg-error`/`libassuan`) don't build under Cygwin+MSVC.
- `--disable-firebird-sdbc` — Firebird's build tools fail on missing UCRT DLLs.
- Rewrites `ATL_INCLUDE`/`ATL_LIB` from `/cygdrive/c` → `C:/` form in `config_host.mk` (cl can't read cygwin paths).
- Imports MSVC `INCLUDE`/`LIB` from `vcvars64.bat` (LO only sets `ILIB`/`SOLARINC`, not the env vars meson externals read).

`PKG_CONFIG=/usr/bin/pkgconf` is exported by the build runner so `autogen` passes
its "windows pkgconf required" check (configure then rewrites it to a Windows
path — harmless, the harfbuzz override below supersedes it).

---

## 4. harfbuzz — the native-meson override (the crux)

harfbuzz is LO's one meson-built external, and Cygwin-meson + native cl is
irreconcilable (POSIX `/tmp` test files cl can't read, pthread, `:`/`;`). Drive
it with the **native** toolchain instead. Patch the run recipe in
`external/harfbuzz/ExternalProject_harfbuzz.mk` (in the cloned `libreoffice/`) so
its meson command becomes:

```make
	$(call gb_ExternalProject_run,build,\
		find . -name "*.py" -exec chmod +x {} + && export PATH="/cygdrive/c/nativetools:$$PATH:/usr/bin" && export CC=cl && export CXX=cl && export INCLUDE="$(gb_ExternalProject_INCLUDE)" && export PKG_CONFIG=C:/nativetools/pkgconf.exe && export PKG_CONFIG_PATH="$$(/usr/bin/cygpath -m $(gb_UnpackedTarball_workdir)/graphite);$$(/usr/bin/cygpath -m $(gb_UnpackedTarball_workdir)/icu)" && \
		/cygdrive/c/Python313/Scripts/meson.exe setup --vsenv --wrap-mode nofallback builddir \
			<keep all the existing -D... options EXCEPT drop "--cross-file cross-file.txt"> && \
		/cygdrive/c/Python313/Scripts/meson.exe compile -C builddir libs \
	)
```

Why each piece matters:

| Piece | Fixes |
|---|---|
| `chmod +x *.py` | tarball unpacks scripts without exec bit; meson runs `gen-hb-version.py` via shebang → `EACCES` |
| `PATH=...:/usr/bin` (usr/bin **last**) | native ninja/pkgconf found first; cl still detected; `touch`/`cygpath` still resolve |
| `CC=cl CXX=cl` | native meson finds cl on the **Windows** PATH (a `/cygdrive` CC path is unusable to it) |
| `INCLUDE=$(gb_ExternalProject_INCLUDE)` | proper `;`-list, no `-I`, exported so the **compile** sees it (cl reads `INCLUDE` for default headers → else `D8038`) |
| `PKG_CONFIG=C:/nativetools/pkgconf.exe` | **Windows-path** native pkgconf (a `/cygdrive` path → meson "Found pkg-config: NO") |
| `PKG_CONFIG_PATH` via `cygpath -m` (`;`) | Windows `C:/…` paths to graphite/icu that native pkgconf can read |
| native `meson.exe` + `--vsenv` | Windows temp paths (no `/tmp` to cl), Windows threads (no `pthread.h`), forces a full MSVC env so cl is always found |
| no `--cross-file` | native meson on Windows already targets Windows correctly |

### graphite2 / icu `.pc` files

harfbuzz needs `graphite2` and `icu-uc` via pkg-config. The `PKG_CONFIG_PATH`
above points at the workdirs where LO generates `graphite2-uninstalled.pc` and
`icu-uc-uninstalled.pc` (these exist by the time harfbuzz builds; graphite/icu
build first). If lookups still fail, copy them into pkgconf's default dir as a
fallback: `cp .../graphite/graphite2-uninstalled.pc /usr/lib/pkgconfig/graphite2.pc`
(and likewise `icu-uc`).

> **TODO to make this push-button:** fold this `.mk` patch into `build.sh` (a
> Windows-gated `sed`/splice after the clone), and install the native toolchain
> in a setup script. Currently the native-toolchain steps are manual.

---

## 5. Run the build

In Cygwin bash, from the repo root, with `SKIP_BRAND=1` (brand separately):

```bash
export SKIP_BRAND=1
export PKG_CONFIG=/usr/bin/pkgconf
./scripts/build.sh
```

This clones `libreoffice-core`, configures, and compiles `libreoffice/instdir`
(~50 min on 16 cores). If a re-run hits `LNK1136: invalid or corrupt file`,
delete zero-byte objects from an interrupted prior run:
`find workdir/CxxObject -name '*.o' -size 0 -delete`.

Success = `instdir/program/soffice.exe` + ~281 DLLs (~550 MB).

---

## 6. Brand + package

Branding essentials (simple copies — no image tools needed on Windows):

```bash
INST=libreoffice/instdir
cp branding/fonts/*.ttf            "$INST/share/fonts/truetype/"
cp -R extensions/auth-gate         "$INST/share/extensions/auth-gate"
cp branding/templates/*.ot?        "$INST/share/template/common/eunifyer/"
echo "26.8.0.0" > "$INST/version"      # read by eunify-desktop's office.rs
```
(Start Center layout + DM Sans *default* are compiled into the fork already; the
font files above make DM Sans actually render.)

Package a portable `.zip` with a clean top folder:

```bash
cd libreoffice && mv instdir "EUnifyer Office"
/usr/bin/zip -r -q -1 /cygdrive/c/EUnifyer-Office-26.8.0.0-windows-x64.zip "EUnifyer Office"
mv "EUnifyer Office" instdir
```
> `scripts/package-windows.ps1` (WiX `.msi`) parses cleanly under PowerShell 7
> (`Language.Parser::ParseFile`) but has never been run end to end on Windows,
> so the `.zip` remains the shipped artifact. See §8 before shipping it again.

> **Auth gate and the Desktop install.** `extensions/auth-gate` asks the user to
> install EUnifyer Desktop when it cannot find one, so it has to recognise every
> name the Desktop installer has ever produced. Tauri's NSIS/WiX bundles key the
> install directory, the executable, the uninstall entry and the shortcut on
> `productName` (`EUnifyer` → `EUnifyer Desktop` → `DriveSync`) and name the
> binary after the cargo package (`eunify-desktop.exe`) unless
> `mainBinaryName` is set. The accepted matrix lives in
> `extensions/auth-gate/python/desktop_detect.py`, the token lookup in
> `token_store.py`; both are pure and unit-tested:
>
> ```bash
> python3 -m unittest discover -s tests   # from the repo root
> ```
>
> Change `productName`, `package.name`, the deep-link scheme or the keyring
> service in `eunify-desktop` and you must update those two modules, or the
> "install Desktop" prompt comes back. Each prompt is also remembered per
> LibreOffice profile (a marker file in `$(user)`), so a dismissed prompt does
> not return — delete the marker to re-arm it while testing.

---

## 8. Authenticode, Mark of the Web, and slow starts

Windows users report 30 s–5 min hangs on every EUnifyer Office launch, which
Defender attributes to scanning and submitting the app's binaries. Two things
make that worse, both ours:

1. **Nothing is signed.** No `signtool` call exists anywhere in this repo —
   `scripts/package-windows.ps1` builds a `.zip` and an optional unsigned WiX
   `.msi`, `.github/workflows/build-windows.yml` has no signing step or
   certificate secret, and the published asset is
   `EUnifyer-Office-<ver>-windows-x64.zip` (288 DLLs, 44 EXEs). The sibling
   `eunify-desktop` installer is unsigned for the same reason
   (`certificateThumbprint: null`).
2. **The `.zip` carries Mark of the Web.** A file downloaded from the internet
   gets a `Zone.Identifier`; extracting it with Explorer copies that marker onto
   every extracted file, so Defender re-evaluates ~330 untrusted, unsigned
   PE files on every launch instead of once at install. `msiexec` installs do
   not propagate the marker to installed files.

Ordered by payoff, all of them need a code-signing certificate first
(OV is enough to stop the unknown-publisher treatment; EV also clears the
SmartScreen "unknown publisher" prompt without waiting for reputation):

1. Ship a **signed MSI** as the primary Windows artifact; keep the `.zip` as an
   opt-in portable download. `scripts/package-windows.ps1` already has the WiX
   path; it needs signing plus a run on a real Windows host.
2. Sign **every** PE file in the payload (DLLs included), not just the entry
   points, and timestamp each signature (`/tr http://timestamp.digicert.com
   /fd sha256`). Sign the MSI/zip last.
3. Keep publishing `SHA256SUMS-windows`, and submit the release to Microsoft
   for malware scanning / reputation so SmartScreen stops re-asking.
4. Also worth doing while in there: `Compress-Archive` in that script is slow
   and memory-hungry at ~230 MB; the documented `/usr/bin/zip -1` path is
   faster.

Until 1–2 land, the local mitigations users can apply are a Defender exclusion
for `%ProgramFiles%\EUnifyer Office` (or their unzipped folder) and turning off
"Automatic sample submission" — both are user-side workarounds, not a fix.

---

## 7. Publish

```bash
gh release upload v26.8.0.0 \
  EUnifyer-Office-26.8.0.0-windows-x64.zip SHA256SUMS-windows \
  --repo EUnifyer/eunify-office-dist --clobber
```

The landing page's Office download section (`eunifyer-landing`
`src/pages/Download.tsx`) currently matches Windows `.exe`/`.msi`; add a
`/\.zip$/i` fallback to its `primaryAssetFor`/`packagesFor` when the portable zip
should surface there.

---

## Gotchas cheat-sheet

- **Nested quoting** (local bash → SSH → PowerShell → Cygwin bash) breaks
  constantly. Write scripts to files, `scp` them, `dos2unix`, run via
  `bash -l /path/script.sh`. For PowerShell `.ps1` with here-strings, keep CRLF.
- **`cl.exe` can't read `/cygdrive/...`** — anything handed to a native tool
  must be `C:/…` (`cygpath -m`).
- **Cygwin meson ≠ native meson.** Use native for the externals.
- **`--vsenv`** is the reliable way to get meson a working MSVC env.
- Tear the VM down (`az group delete`) — it bills while idle.
