#!/usr/bin/env python3
"""P4-W: wire (or unwire) the HCCWatch app into the OpenVitals iOS target.

Two lines decide whether the iOS app embeds the watch app: one entry in the
OpenVitals target's `buildPhases` (the Embed Watch Content copy phase) and one
in its `dependencies`. Everything else the watch app needs — the target, its
phases, its build configurations, the copy phase itself, the container proxy and
the target dependency object — is already in the project either way.

They are OFF in the checked-in project because this Mac has no watchOS 26.5
platform installed, and Xcode refuses to build ANY scheme that embeds a watch
app without it:

    xcodebuild: error: Failed to build project OpenVitals with scheme
    OpenVitals.: This scheme builds an embedded Apple Watch app. watchOS 26.5
    must be installed in order to run the scheme

Installing it is `xcodebuild -downloadPlatform watchOS` (3.96 GB download, and
the boot volume was at 98 % with 20 GB free when this was written — which is why
it was not done unilaterally).

    python3 Scripts/embed_watch.py on     # embed the watch app in the iOS app
    python3 Scripts/embed_watch.py off    # unwire it (the shipped state)
    python3 Scripts/embed_watch.py status
"""
import sys

PBX = "/Users/cgatbonton/Documents/openvitals/OpenVitals.xcodeproj/project.pbxproj"

PHASE_ANCHOR = "\t\t\t\tB60000000000000000000003 /* Embed App Extensions */,\n"
PHASE_LINE = "\t\t\t\tE60000000000000000001604 /* Embed Watch Content */,\n"
DEP_ANCHOR = "\t\t\t\tB70000000000000000000002 /* PBXTargetDependency */,\n"
DEP_LINE = "\t\t\t\tE70000000000000000001602 /* PBXTargetDependency */,\n"

mode = sys.argv[1] if len(sys.argv) > 1 else "status"
src = open(PBX, encoding="utf-8").read()
wired = PHASE_LINE in src and DEP_LINE in src

if mode == "status":
    print("embedded" if wired else "not embedded")
    sys.exit(0)

if mode == "on":
    if wired:
        print("already embedded")
        sys.exit(0)
    for anchor, line in ((PHASE_ANCHOR, PHASE_LINE), (DEP_ANCHOR, DEP_LINE)):
        assert src.count(anchor) == 1, f"anchor not unique: {anchor!r}"
        src = src.replace(anchor, anchor + line)
elif mode == "off":
    if not wired:
        print("already not embedded")
        sys.exit(0)
    for line in (PHASE_LINE, DEP_LINE):
        assert src.count(line) == 1, f"line not unique: {line!r}"
        src = src.replace(line, "")
else:
    sys.exit(__doc__)

open(PBX, "w", encoding="utf-8").write(src)
print(f"embed watch content: {mode}")
