---
name: catplan:init
description: Detect tech stacks in the repo and generate .catplan/project.json.
user-invocable: true
---

# catplan:init

## Overview
Detect tech stacks in the current repository and generate a `.catplan/project.json` configuration file. This file tells CatPlan agents how to build and test each stack in your project.

## Trigger
User invokes `/catplan:init` from repo root.

## Flow

### Step 1 — Overwrite guard
- Check if `.catplan/project.json` exists
- If YES: ask "Found existing .catplan/project.json. Overwrite? [y/N]"
  - N or empty → "Aborted." → stop
  - Y → continue

### Step 2 — Crawl for stack markers
- Scan: repo root files; each depth-1 subdirectory's files
- Skip directories: `node_modules/`, `.git/`, `dist/`, `build/`, `target/`, `.catplan/`
- Use Glob tool for each marker pattern; record (marker, path)
- For each `package.json` found: read it with the Read tool; extract keys from
  `dependencies` and `devDependencies`

### Step 3 — Resolve stacks
- Apply detection table (see below) to produce stack entries
- Node framework resolution order: SvelteKit → Next.js → Vue → React → plain Node
- Deduplication rule: if same stack type appears at root AND a subdirectory, keep only root
- Makefile: only include if NO other marker was found in that directory
- `pyproject.toml`: takes priority over `requirements.txt` (only one python stack)
- If no markers found: notify user, suggest manual creation, stop

### Step 4 — Present draft
- Print: "Detected N stack(s): \<names\>"
- Print full proposed `.catplan/project.json` (formatted JSON)
- Ask: "Write this file? [y/N/edit]"

### Step 5 — Handle response
- y → go to Step 6
- n → "Aborted. No file written." → stop
- edit → "Describe changes (or paste corrected JSON):" → apply, loop back to Step 4

### Step 6 — Write
- Create `.catplan/` directory if needed (mkdir)
- Write `.catplan/project.json` with confirmed JSON content
- Print: "✓ .catplan/project.json written."

## Stack Detection Table

| Marker | Condition | Stack Name | detect[] | build | test |
|--------|-----------|------------|----------|-------|------|
| package.json | @sveltejs/kit in deps | sveltekit | ["package.json","src/**/*.svelte","src/**/*.ts"] | "npm run build" | ["npm run check","npm test"] |
| package.json | next in deps | nextjs | ["package.json","app/**/*.tsx","pages/**/*.tsx"] | "npm run build" | "npm test" |
| package.json | vue in deps | vue | ["package.json","src/**/*.vue","src/**/*.ts"] | "npm run build" | "npm test" |
| package.json | react in deps (no svelte/next/vue) | react | ["package.json","src/**/*.tsx","src/**/*.jsx"] | "npm run build" | "npm test" |
| package.json | no known framework | node | ["package.json","src/**/*.ts","src/**/*.js"] | null | "npm test" |
| go.mod | — | go | ["go.mod","**/*.go"] | "go build ./..." | "go test ./..." |
| Cargo.toml | — | rust | ["Cargo.toml","src/**/*.rs"] | "cargo build" | "cargo test" |
| *.uproject | — | unreal | ["*.uproject","Source/**/*.cpp","Source/**/*.h"] | null | {"type":"skill","name":"unreal-build-and-test"} |
| pyproject.toml | — | python | ["pyproject.toml","**/*.py"] | null | "pytest" |
| requirements.txt | no pyproject.toml | python | ["requirements.txt","**/*.py"] | null | "pytest" |
| pom.xml | — | java | ["pom.xml","src/**/*.java"] | "mvn compile -q" | "mvn test -q" |
| build.gradle / build.gradle.kts | — | gradle | ["build.gradle","build.gradle.kts","**/*.kt","**/*.java"] | "./gradlew build" | "./gradlew test" |
| *.sln | — | dotnet | ["*.sln","**/*.cs"] | "dotnet build" | "dotnet test" |
| Makefile | no other marker | make | ["Makefile"] | "make build" | "make test" |

## JSON Output Schema

```json
{
  "stacks": [
    {
      "name": "<stack-name>",
      "detect": ["<glob>", "..."],
      "build": "<command> | [<cmd1>,<cmd2>] | {type:skill,name:...} | null",
      "test":  "<command> | [<cmd1>,<cmd2>] | {type:skill,name:...} | null"
    }
  ]
}
```

## Key Behaviors
- Never write to disk without explicit `y` from user
- Never silently overwrite existing `.catplan/project.json`
- Skill is self-contained — no external docs required
- Skip `node_modules/`, `.git/`, `dist/`, `build/`, `target/`, `.catplan/` during scan
- edit branch: accept freeform natural language or pasted JSON; apply and re-present
- Prefer Glob tool for marker detection, Read tool for `package.json` content

## Maintenance
Changes require plugin reinstall. `/reload-plugins` reloads from plugin cache only —
reinstall from source to pick up edits.
