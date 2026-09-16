# Getting started

Start here. At the end you will have one sentence about your Swing application —
*N concurrent active users fit in a B GB budget on Swing Bridge 1.3.0, at this heap* —
with the evidence behind it. The whole path is about a day of machine time, most of it
unattended, and less than an hour of yours.

You need **two Linux machines on the same wired network**. Call them **Box A**, where your
application will run, and **Box B**, which will run one Chromium browser per simulated
user. You only ever type on Box A.

## Before you begin

**On Box A** (Debian or Ubuntu names; use your distribution's equivalents):

```
sudo apt install openjdk-21-jdk maven python3 git rsync curl openssh-client iproute2
```

The kit enforces the memory budget with a systemd scope, which needs cgroup v2 with the
memory controller delegated to your user. Most current distributions do this already.
Check:

```
stat -fc %T /sys/fs/cgroup                # must print: cgroup2fs
ls /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/memory.max
```

If the second command finds no file, [SETUP.md](SETUP.md), *Box A*, has the four-line
fix. The kit checks all of this itself and stops with the reason if anything is missing;
it never installs anything.

**On Box B:**

```
sudo apt install openjdk-21-jdk maven rsync curl openssh-server
```

Box B needs no copy of the kit, no git and no credentials. Box A puts everything there.
Chromium's own system libraries are needed once; step 6 says how, if they turn out to be
missing.

**Also:** your application's jar file(s), and a Vaadin licence. The small project your
application runs in depends on Vaadin's commercial components, so building it validates
your licence the way any Vaadin project does. If the build stops on a licence check, do
what it prints.

## 1. Put the kit on Box A

```
git clone <the kit's address>
cd swingbridge-sizing-kit-dev
```

## 2. Let Box A reach Box B over ssh

The kit drives everything on Box B from Box A over `ssh`, unattended, for hours. So Box A
must log in to Box B **without being asked for a password**, and the connection must stay
up. On Box A:

```
ssh-keygen -t ed25519 -f ~/.ssh/sizing_boxb -N ""
ssh-copy-id -i ~/.ssh/sizing_boxb.pub <your user on Box B>@<Box B's address>
```

You are asked for Box B's password once, here, and never again. Then give Box B a name,
so the kit never needs its address. Add to `~/.ssh/config` on Box A (create the file if
it does not exist):

```
Host boxb
    HostName <Box B's address>
    User <your user on Box B>
    IdentityFile ~/.ssh/sizing_boxb
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

The last two lines keep the connection alive during long runs. Test it:

```
ssh boxb hostname
```

It must print Box B's name and ask you nothing. If it asks for a password, the key did not
install; if it hangs, the address or a firewall is wrong.

**Box B must also reach Box A**, on two ports: 8088, where your application will answer,
and 8099, a small helper the kit runs beside it. If a firewall sits between the machines,
open both from Box B's side. The kit checks this and tells you if it fails.

## 3. Run `./runBoxA.sh` for the first time

```
./runBoxA.sh
```

It has nothing to work with yet, so it sets the box up. It checks that the tools above are
installed, then asks five questions:

- where to put the small Vaadin project your application will run in — press Enter for the
  default, `system-under-test/` inside the kit;
- the **main class** of your Swing application, such as `com.acme.inventory.Main`;
- the arguments its `main()` takes, if any — Enter for none;
- the ssh name of Box B — `boxb`, from step 2;
- the memory budget to size for, in GB — `4` for a 4 GB machine.

It proves the budget can be enforced, writes your answers to `harness/harness.env` (plain
text; you can edit it later), downloads the Vaadin starter project for Swing Bridge, adds
one page to it that starts your main class, and stops with two instructions. They are
steps 4 and 5.

## 4. Put your jar where it said

Copy your application's jar — and its dependencies, and nothing else — into the `applibs/`
folder it named. Every jar in that folder is on your application's classpath.

Your application must do two things it may not do today. Both are described in
[README.md](README.md), *What your application must do*; in short:

- **Print where its widgets are.** While it runs, print one line per update to standard
  output, `WIDGET-BOUNDS {"t":<ms>,"window":[w,h],"widgets":{"name":[x,y,w,h],…}}`: a
  timestamp, the window size, and the rectangle of each part of the screen the test will
  click or watch. Every click is aimed and every result checked from this line, so nothing
  in the test is a guessed pixel. [SCENARIO.md](SCENARIO.md) has the details.
- **Show its first window within five seconds** of starting, and at a fixed size.

## 5. Write your scenario

A scenario is what one user does, step by step — *click here, press this key* — with, for
each step, the parts of the screen that must change as a result. It is a short JSON file;
[SCENARIO.md](SCENARIO.md) explains every line, and `examples/josm/josm-cycle.json` is a
complete real one. Save yours at the path the first run named (by default
`harness/scenario/app-cycle.json`).

To check it in seconds instead of after a long run: start your application once on its own
so it prints a `WIDGET-BOUNDS` line, save that output to a file, and in step 6 run
`SIZING_BOUNDS_SAMPLE=<that file> ./runBoxA.sh`. The kit then resolves every click and every
watched region against what your application actually published, with no browser.

## 6. Run `./runBoxA.sh` again

```
./runBoxA.sh 2>&1 | tee -a ~/sizing.log
```

Now it prepares everything, and says so as it goes: checks your main class is in your jar;
reads your jar's manifest for module flags it must repeat; builds the project with your jar
in it (slow the first time — the frontend toolchain downloads); composes the exact command
the server will start with; checks `boxb` answers; **proves** the memory limit holds by
starting a limited process and reading the limit back; checks your scenario if you gave it
a sample; then copies the kit to Box B and sets Box B up there — builds the browser driver,
downloads Chromium. A few minutes. Box B is finished after this.

If anything is wrong it stops and says what, by name. Nothing after this produces a number
until it passes. One thing it cannot check for you: **Chromium's system libraries on
Box B.** If the first cell in step 7 stops with browsers that cannot start, run once on
Box B, inside the kit's directory there, with privileges:

```
sudo java -cp "driver/target/classes:driver/target/dependency/*" com.microsoft.playwright.CLI install-deps chromium
```

## 7. Run `./runSizing.sh` — the picture

```
./runSizing.sh 2>&1 | tee -a ~/sizing.log
./runReport.sh
```

The long one. The kit tries three settings of the Java heap — 60, 70 and 80 % of your
budget — and for each starts your application inside the memory limit and adds users one
at a time, each working through your scenario continuously, until the group can no longer
keep up or the server runs out of memory. About half an hour per setting for an
application that fits around forty users; the terminal shows the plan and the estimate
before anything starts. Let it run.

Then open `harness/reports/<date>-report.md`. For each heap setting: how many users fit,
whether that result is trustworthy, whether the heap or the memory limit ran out first,
and how full the heap was at the end. One run per setting is a picture, not a number to
publish; the report says so itself.

## 8. Choose a heap

Usually one setting fits the most users cleanly; a larger one is killed by the memory
limit, a smaller one runs the heap dry. Pick the one you would deploy with. If a heap the
picture did not try looks promising, one more run there is half an hour:
`SB_CAPS=<heap> ./runSizing.sh`.

## 9. Run three times at your heap — the number

```
SB_CAPS=<your heap> SIZING_REPEATS=3 ./runSizing.sh 2>&1 | tee -a ~/sizing.log
./runReport.sh
```

Another hour and a half. The report now opens with the sentence — the middle of your three
runs — with every run, every check and every file behind it listed below. That is your
result.

## When something stops

Every script stops with a message that names the cause and, where there is one, the fix.
The report names what ran out first — the memory budget, the Java heap, the browsers'
machine, or the five-second start-up limit — and each points at a different remedy.
[SETUP.md](SETUP.md), *Things that have already cost readings*, lists the traps.

## Where things are

- `harness/harness.env` — every setting, plain text. The block at the top is rewritten by
  `runBoxA.sh` on each run; your lines below it win. `harness/harness.env.example`
  documents every setting the kit knows.
- `harness/reports/` — one log, one memory CSV and one samples CSV per cell, the sizing
  manifest per `runSizing.sh`, and the reports.
- `system-under-test/` — the Vaadin project your application runs in, with your jar in `applibs/`.
- On Box B, everything lives under one directory the kit chose; nothing else there is
  touched.

## Trying the kit before your own application

`examples/josm/README.md` runs the kit against JOSM, the application it was built with:
a production-sized Swing program with a ready-made scenario. It is the quickest way to see
a complete run end to end.
