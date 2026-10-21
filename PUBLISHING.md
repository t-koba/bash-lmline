# Publishing Checklist

Before publishing:

Requires `bash` 4.2 or newer and `rg` (ripgrep) for the privacy scan in
`./scripts/privacy-scan.sh`; the scan fails closed when `rg` is missing.

1. Ensure `request.md` is not included in the repository or release artifact. It is ignored by `.gitignore` and marked `export-ignore` in `.gitattributes`; do not force-add it.
2. Run:

   ```bash
   bash --version
   ./scripts/publish-check.sh
   ```

   The bundled engine and Bash integration require bash 4.2 or newer.

3. Confirm the commit subjects that follow the charter are one plain imperative
   sentence with no internal identifier:

   ```bash
   bash scripts/check-commit-subjects.sh
   ```

   `scripts/publish-check.sh` runs the same check before it packages anything.
   The check reads the history to find the commit that added the charter, so
   it needs the whole history; a truncated clone is reported as an error.

4. Check that the tree holds no private data: local paths and user names,
   private host names (private network addresses and internal host names),
   credentials, personal addresses and secret-like file names:

   ```bash
   bash scripts/privacy-scan.sh
   ```

   The patterns live in `scripts/privacy-scan.sh`, so this check and
   `./scripts/publish-check.sh` always look for the same things. The scan
   reads the tree it is given, so it may be run from any directory; give it
   a directory to scan another tree.

5. Confirm generated config/state is not staged:

   ```bash
   git status --short
   ```

6. Verify install into a temporary directory:

   ```bash
   tmp=$(mktemp -d)
   LMLINE_CONFIG_DIR="$tmp/config" LMLINE_BIN_DIR="$tmp/bin" ./install.sh
   LMLINE_CONFIG_DIR="$tmp/config" "$tmp/bin/lmline" doctor
   ```

7. Confirm `README.md`, `SECURITY.md`, and `LICENSE` are present.

8. If publishing a GitHub source archive, confirm `.gitattributes` is present so local-only files marked `export-ignore` are excluded from generated archives.
