# openvitals (hcc-provider) — working notes for agents

This is a **fork** of `jeffgat/openvitals`, a SwiftUI + Rust iOS app that reads a
BLE wearable locally. Our branch adds a second data source: **HCC provider mode**,
in which the app is a thin client of the owner's self-hosted Health Command
Center server and computes nothing itself.

- Work on **`hcc-provider`**. Never commit to `main`, never push to `upstream`.
- **`docs/hcc-provider.md` is the rulebook for everything we added.** Read it
  before changing HCC code — copy rule, card spacing, civil days, the write
  pattern, never-fabricate, the debug launch hooks, and a section per feature.
  It is the single home for those rules: point at it, do not restate it here or
  in a memory file.
- **`AGENTS.md` is upstream's** and still binds: new code goes in new files under
  `OpenVitals/HCC/`, touch points in existing files stay minimal and
  `// HCC:`-commented, and the BLE and Rust paths are never rewritten.

## The other half lives in another repo

The server is `/Users/cgatbonton/Documents/health-command-center` (Next.js +
Prisma). Most behaviour questions — a value, a threshold, a grading, what an
insight says — are answered there, not here. Check the API response before
changing a view. That repo's `mobile-app` skill routes a change to the right
side and carries the build, install and verification loop.

## Non-obvious things that bite

- **New files must be registered by hand in `project.pbxproj`** in four places
  (`PBXBuildFile`, `PBXFileReference`, the group's `children`, the target's
  `Sources`). Id blocks `01`-`16` are used. A `path` containing `+` **must be
  quoted** or the project stops parsing for everyone. `plutil -lint` after every
  edit.
- **The Rust core is force-loaded**, so `Rust/<sdk>/libopen_vitals_core.a` must
  exist. `OPENVITALS_SKIP_RUST_CORE_BUILD=1` is only safe once it does.
- **There is no test target and no UI automation.** Verification is a clean build
  plus `HCC_DEBUG_*` launch hooks and `simctl` screenshots. Nothing can tap, so
  anything behind a system permission alert stays unverified — say so rather than
  implying coverage.
- **Never type a credential into the app** to verify something. Inject a mobile
  token through the debug launch environment.
- Point verification at a **local backend and its throwaway database**, never the
  owner's production instance.

## More than one session may be working in this checkout

Two Claude sessions have shared this working tree at once, and a `git add -A`
from one of them swept the other's in-progress files into an unrelated commit.
Stage the files you actually changed, by path. If `git status` shows edits you
did not make, leave them alone and say so rather than committing them.

## Health data

This app displays one person's health data. Do not paste real values into code,
comments, fixtures, or commit messages, and do not add analytics or crash
reporting that would send them anywhere.
