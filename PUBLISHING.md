# Publishing Checklist

Before publishing:

1. Ensure `request.md` is not included in the repository or release artifact. It is ignored by `.gitignore` and marked `export-ignore` in `.gitattributes`; do not force-add it.
2. Run:

   ```bash
   bash --version
   ./scripts/publish-check.sh
   ```

   The bundled engine and Bash integration require bash 4.2 or newer.

3. Check for local paths, private hostnames, secrets, and personal model names:

   ```bash
   rg -n '(/Users/|Mac-Air|local/llm-completion|BEGIN .*PRIVATE|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})' -uu --glob '!PUBLISHING.md' --glob '!scripts/publish-check.sh' --glob '!request.md' .
   ```

4. Confirm generated config/state is not staged:

   ```bash
   git status --short
   ```

5. Verify install into a temporary directory:

   ```bash
   tmp=$(mktemp -d)
   LMLINE_CONFIG_DIR="$tmp/config" LMLINE_BIN_DIR="$tmp/bin" ./install.sh
   LMLINE_CONFIG_DIR="$tmp/config" "$tmp/bin/lmline" doctor
   ```

6. Confirm `README.md`, `SECURITY.md`, and `LICENSE` are present.

7. If publishing a GitHub source archive, confirm `.gitattributes` is present so local-only files marked `export-ignore` are excluded from generated archives.
