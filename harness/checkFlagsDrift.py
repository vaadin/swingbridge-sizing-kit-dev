#!/usr/bin/env python3
"""Does the clone's spring-boot:run <jvmArguments> still match jvm-flags.conf?

The kit launches the packaged jar with its own flag list, because in production
the pom's <jvmArguments> do not apply. That leaves one exposure: skeleton-starter
moves and the kit's list quietly falls behind. This reads the customer's pom
STRUCTURALLY -- the first spring-boot-maven-plugin <jvmArguments> block, which is
the default build's -- and compares token by token with the kit's list, after
mapping the pom's own property references onto the kit's placeholders.

Exit 0: identical. Exit 1: drift, both directions listed. Exit 2: no such block.

Usage:
  checkFlagsDrift.py <clone>/pom.xml jvm-flags.conf
"""
import sys
import xml.etree.ElementTree as ET

NS = {"m": "http://maven.apache.org/POM/4.0.0"}
M = "{%s}" % NS["m"]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    pom, conf = sys.argv[1], sys.argv[2]
    root = ET.parse(pom).getroot()
    props_el = root.find("m:properties", NS)
    props = {c.tag.replace(M, ""): (c.text or "").strip()
             for c in (props_el if props_el is not None else [])}

    blocks = []
    for plugin in root.iter(M + "plugin"):
        if plugin.findtext("m:artifactId", default="", namespaces=NS) \
                == "spring-boot-maven-plugin":
            for ja in plugin.iter(M + "jvmArguments"):
                blocks.append(ja.text or "")
    if not blocks:
        print("  WARN  flags drift: no spring-boot-maven-plugin <jvmArguments>"
              " in %s -- nothing to compare against" % pom)
        return 2

    PLACEHOLDERS = {"settings.localRepository": "@LOCAL_REPO@",
                    "swing-bridge.version": "@SB_VERSION@"}

    def normalise(tok):
        # The two values the kit renders at run time become placeholders FIRST,
        # so the pom's own value for swing-bridge.version never leaks in as a
        # literal; then the pom's other properties (swing-bridge.path is
        # ${settings.localRepository}/com/vaadin) expand until stable.
        for k, ph in PLACEHOLDERS.items():
            tok = tok.replace("${%s}" % k, ph)
        for _ in range(5):
            before = tok
            for k, v in props.items():
                if k not in PLACEHOLDERS:
                    tok = tok.replace("${%s}" % k, v)
            for k, ph in PLACEHOLDERS.items():
                tok = tok.replace("${%s}" % k, ph)
            if tok == before:
                break
        return tok

    pom_tokens = []
    for tok in blocks[0].split():
        if tok.startswith(("-agentlib", "-Xdebug", "-Xrunjdwp")):
            continue                     # never part of a measured run
        pom_tokens.append(normalise(tok))
    conf_tokens = [l.strip() for l in open(conf)
                   if l.strip() and not l.lstrip().startswith("#")]

    only_kit = [t for t in conf_tokens if t not in pom_tokens]
    only_pom = [t for t in pom_tokens if t not in conf_tokens]
    if not only_kit and not only_pom:
        print("  OK    flags drift             none: %d entries in %s match the"
              " clone's spring-boot:run set" % (len(conf_tokens), conf.split("/")[-1]))
        return 0
    print("  WARN  flags drift             the clone's pom and %s differ:"
          % conf.split("/")[-1])
    for t in only_pom:
        print("          in the clone's pom, not in the kit: %s" % t)
    for t in only_kit:
        print("          in the kit, not in the clone's pom: %s" % t)
    print("          The kit launches with ITS list. If the pom is the newer"
          " one, update jvm-flags.conf and say so in the run's notes.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
