#!/usr/bin/env node
import { installMain } from "./install.mjs";

// Refresh rewrites the unit file; still requires --apply for real writes.
process.exitCode = installMain(process.argv.slice(2));
