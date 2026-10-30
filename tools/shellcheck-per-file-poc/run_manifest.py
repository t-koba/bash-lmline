#!/usr/bin/env python3
"""Test-only entry point for the unchanged production Bash manifest."""
import sys
from candidate import main, production_manifest

if __name__ == "__main__":
    sys.exit(main(production_manifest()))
