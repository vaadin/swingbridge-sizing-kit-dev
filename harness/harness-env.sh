# shellcheck shell=bash
# Sourced by every harness script. The one place where anything that differs
# between machines is decided.
#
# Why this file exists: the rig grew defaults pointing at the boxes it happened
# to run on, and by round 2 those spanned TWO different home directories
# (/home/eftun and /home/eftunv) plus an address that had already moved five
# times. None of it failed loudly. A guest-jar default pointing into another
# user's home produced a complete, well-formatted cell of zeros -- 0 tenants,
# 320 MB, no error but a ClassNotFoundException buried in a server log -- and
# the round-2 sweeps themselves only worked because one shell session happened
# to export the right path, which is recorded nowhere. Nobody outside that
# session could have reproduced them.
#
# So: every default here derives from $HOME or is detected at run time, and
# every one can be overridden by exporting the variable. Run ./checkEnv.sh to
# see what resolved and whether it actually exists.
#
# Per-box overrides belong in harness.env beside this file (gitignored):
#     BOXB=loadgen-1
# It is sourced here if present, before the defaults, so it wins.

# Where the harness and the repo are, regardless of where you invoked from.
: "${HARNESS_HOME:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${REPO_ROOT:=$(cd "$HARNESS_HOME/.." && pwd)}"

[ -f "$HARNESS_HOME/harness.env" ] && . "$HARNESS_HOME/harness.env"

# ---------------------------------------------------------------- this box
# How the load box must address THIS one. Detected rather than written down:
# the address has changed five times, twice onto a different subnet, and a
# stale literal here means the generator drives nothing while the server sits
# idle looking healthy.
: "${A_IP:=$(ip -4 -o addr show scope global 2>/dev/null \
             | awk '{split($4,a,"/"); print a[1]; exit}')}"

# ---------------------------------------------------------------- the guest
# The JOSM guest. Deliberately outside the tree: JOSM is GPLv2 and this is a
# commercial repository. $HOME-relative so it resolves per user instead of for
# one particular account.
: "${JOSM_JAR:=$HOME/dev/josm/josm-web-patched.jar}"
: "${JOSM_SRC:=$HOME/dev/josm/josm}"

# ------------------------------------------------------------ the load box
# ssh alias for the generator. Keep the real address in ~/.ssh/config, not
# here, so it can move without touching the rig.
: "${BOXB:=boxb}"

export HARNESS_HOME REPO_ROOT A_IP JOSM_JAR JOSM_SRC BOXB
