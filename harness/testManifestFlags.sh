#!/usr/bin/env bash
# Every branch of manifestFlags.py, against jars built here and a stub java that
# answers --list-modules / --describe-module from fixtures, so the module filter is
# pinned rather than left to whichever JDK runs the test.
#   ./testManifestFlags.sh [-v]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
      else FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; return 0; }

# --- a stub java: three modules, their packages, and a call log
BIN="$TMP/bin"; mkdir -p "$BIN"; CALLS="$TMP/calls"; : > "$CALLS"
cat > "$BIN/java" <<S
#!/usr/bin/env bash
echo "java \$*" >> "$CALLS"
case "\$1" in
  --list-modules) printf '%s\n' java.base@21.0.12 java.desktop@21.0.12 java.prefs@21.0.12 ;;
  --describe-module)
    case "\$2" in
      java.base)    printf '%s\n' 'java.base@21.0.12' 'exports java.lang' 'exports java.nio' \
                      'qualified exports sun.security.util to java.rmi java.desktop' \
                      'qualified exports sun.security.x509 to jdk.jartool' \
                      'qualified exports jdk.internal.ref to java.desktop' \
                      'qualified exports jdk.internal.loader to java.instrument' \
                      'contains sun.security.action' 'requires java.base mandated' ;;
      java.desktop) printf '%s\n' 'java.desktop@21.0.12' 'exports javax.imageio.spi' 'exports javax.swing.text.html' \
                      'contains com.sun.imageio.plugins.jpeg' 'contains com.sun.imageio.spi' 'uses javax.sound.sampled.spi.MixerProvider' ;;
      java.prefs)   printf '%s\n' 'java.prefs@21.0.12' 'exports java.util.prefs' ;;
      *)            echo "Error: module \$2 not found" >&2; exit 1 ;;
    esac ;;
esac
S
chmod +x "$BIN/java"
# --- jars built from a manifest text (or none)
mkjar() { python3 - "$@" <<'PY'
import sys, zipfile
path, manifest = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
with zipfile.ZipFile(path, "w") as zf:
    zf.writestr("Hello.class", b"\xca\xfe\xba\xbe")
    if manifest is not None:
        zf.writestr("META-INF/MANIFEST.MF", manifest)
PY
}
# The real patched JOSM jar's manifest, byte for byte: CRLF, 72-byte wrap, continuation lines.
JOSM_MF=$'Manifest-Version: 1.0\r\nMain-class: org.openstreetmap.josm.gui.MainApplication\r\nPermissions: all-permissions\r\nCodebase: josm.openstreetmap.de\r\nApplication-Name: JOSM - Java OpenStreetMap Editor\r\nAdd-Exports: java.base/sun.security.util java.desktop/com.apple.eawt jav\r\n a.desktop/com.sun.imageio.spi javafx.graphics/com.sun.javafx.applicatio\r\n n jdk.deploy/com.sun.deploy.config\r\nAdd-Opens: java.base/java.lang java.base/java.nio java.base/jdk.internal\r\n .loader java.base/jdk.internal.ref java.base/sun.security.x509 java.des\r\n ktop/javax.imageio.spi java.desktop/com.sun.imageio.plugins.jpeg java.d\r\n esktop/javax.swing.text.html java.prefs/java.util.prefs\r\n\r\nName: some/entry.class\r\nSHA-256-Digest: abc\r\n'
mkjar "$TMP/josm.jar" "$JOSM_MF"
mkjar "$TMP/plain.jar" $'Manifest-Version: 1.0\nCreated-By: Maven JAR Plugin 3.4.1\n\n'
mkjar "$TMP/nomanifest.jar"
mkjar "$TMP/lower.jar" $'manifest-version: 1.0\nadd-exports:   java.desktop/com.sun.imageio.spi   java.base/sun.security.action\nADD-OPENS: java.prefs/java.util.prefs\n'
mkjar "$TMP/overlap.jar" $'Manifest-Version: 1.0\nAdd-Opens: java.base/java.lang java.desktop/javax.swing.text.html\nAdd-Exports: java.base/sun.security.util\n'
mkjar "$TMP/malformed.jar" $'Manifest-Version: 1.0\nAdd-Exports: java.base a/b/c java.base/java.nio /x y/\n'
mkjar "$TMP/entryonly.jar" $'Manifest-Version: 1.0\n\nName: x\nAdd-Exports: java.base/java.lang\n'
echo "not a zip" > "$TMP/broken.jar"
run() { (cd "$TMP" && PATH="$BIN:/usr/bin:/bin" JAVA_HOME= python3 "$OLDPWD/manifestFlags.py" "$@"); }
EXPECT_JOSM='--add-exports=java.base/sun.security.util=ALL-UNNAMED --add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/jdk.internal.loader=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED --add-opens=java.base/sun.security.x509=ALL-UNNAMED --add-opens=java.desktop/javax.imageio.spi=ALL-UNNAMED --add-opens=java.desktop/com.sun.imageio.plugins.jpeg=ALL-UNNAMED --add-opens=java.desktop/javax.swing.text.html=ALL-UNNAMED --add-opens=java.prefs/java.util.prefs=ALL-UNNAMED'

echo "the JOSM manifest: continuation lines, CRLF, unknown module and package"
: > "$CALLS"; out=$(run josm.jar 2>"$TMP/err"); rc=$?
ok "exit 0"                                        "0" "$rc"
ok "11 flags, manifest order, exports then opens"  "$EXPECT_JOSM" "$out"
ok "three skipped, each with its reason"           "3" "$(grep -c '^skipped josm.jar: ' "$TMP/err")"
ok "  a package the module lacks"                  "yes" "$(grep -q 'java.desktop/com.apple.eawt -- java.desktop has no package com.apple.eawt' "$TMP/err" && echo yes)"
ok "  a module the JDK lacks (two)"                "2" "$(grep -c -- '-- no module .* in this JDK' "$TMP/err")"
ok "the JDK asked once per module, list once"      "1 3" "$(grep -c 'java --list-modules' "$CALLS") $(grep -c 'java --describe-module' "$CALLS")"
ok "  and never for a module it does not list"    "0" "$(grep -c 'describe-module jdk.deploy\|describe-module javafx' "$CALLS")"
out=$(run --by-jar josm.jar 2>/dev/null)
ok "--by-jar: one line per flag, jar first"        "11 11" "$(printf '%s\n' "$out" | wc -l) $(printf '%s\n' "$out" | grep -c $'^josm.jar\t--add-')"

echo "nothing to derive"
ok "a manifest without the attributes -> empty, 0"  "|0" "$(o=$(run plain.jar 2>&1); echo "$o|$?")"
ok "a jar without a manifest -> empty, 0"           "|0" "$(o=$(run nomanifest.jar 2>&1); echo "$o|$?")"
ok "attributes in a per-entry section do not count" "|0" "$(o=$(run entryonly.jar 2>&1); echo "$o|$?")"

echo "lenient where the spec is"
out=$(run lower.jar 2>/dev/null)
ok "lowercase names, LF, extra spaces"             "--add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED --add-exports=java.base/sun.security.action=ALL-UNNAMED --add-opens=java.prefs/java.util.prefs=ALL-UNNAMED" "$out"
out=$(run malformed.jar 2>"$TMP/err"); rc=$?
ok "malformed entries skipped, the good one kept"  "--add-exports=java.base/java.nio=ALL-UNNAMED|0" "$out|$rc"
ok "  each named as not module/package"            "4" "$(grep -c "is not module/package" "$TMP/err")"

echo "several jars"
out=$(run overlap.jar josm.jar 2>/dev/null)
ok "deduplicated; first jar first, its exports before its opens" "--add-exports=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.desktop/javax.swing.text.html=ALL-UNNAMED --add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED" "$(printf '%s\n' "$out" | tr ' ' '\n' | head -4 | tr '\n' ' ' | sed 's/ $//')"
ok "  eleven distinct in all"                      "11" "$(printf '%s\n' "$out" | tr ' ' '\n' | wc -l)"
ok "  --by-jar credits the first jar"              "overlap.jar" "$(run --by-jar overlap.jar josm.jar 2>/dev/null | grep 'java.base/java.lang' | cut -f1)"

echo "refusals"
ok "not a zip -> 1, names the file"                "1 yes" "$(o=$(run broken.jar 2>&1); echo "$? $(case "$o" in *"broken.jar: not a readable jar"*) echo yes;; esac)")"
ok "a missing file -> 1, names it"                 "1 yes" "$(o=$(run nosuch.jar 2>&1); echo "$? $(case "$o" in *"nosuch.jar: not a readable jar"*) echo yes;; esac)")"
ok "no jars -> 2, usage"                           "2 yes" "$(o=$(run 2>&1); echo "$? $(case "$o" in *"manifestFlags.py [--java"*) echo yes;; esac)")"
ok "an unknown option -> 1"                        "1" "$(run --frob josm.jar >/dev/null 2>&1; echo $?)"

echo "which java decides"
printf '#!/usr/bin/env bash\ncase "$1" in --list-modules) echo java.base@17;; --describe-module) echo "exports java.lang";; esac\n' > "$TMP/tiny-java"; chmod +x "$TMP/tiny-java"
ok "--java: a JDK with one module keeps one flag"  "--add-opens=java.base/java.lang=ALL-UNNAMED" "$(run --java "$TMP/tiny-java" josm.jar 2>/dev/null)"
mkdir -p "$TMP/jh/bin"; cp "$TMP/tiny-java" "$TMP/jh/bin/java"
ok "JAVA_HOME honoured when --java is absent"      "--add-opens=java.base/java.lang=ALL-UNNAMED" "$(cd "$TMP" && PATH="$BIN:/usr/bin:/bin" JAVA_HOME="$TMP/jh" python3 "$OLDPWD/manifestFlags.py" josm.jar 2>/dev/null)"
ok "a java that cannot run -> 1, says so"          "1 yes" "$(o=$(run --java /nonexistent/java josm.jar 2>&1); echo "$? $(case "$o" in *"cannot run /nonexistent/java"*) echo yes;; esac)")"

echo
if [ "$FAIL" -eq 0 ]; then printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1; fi
