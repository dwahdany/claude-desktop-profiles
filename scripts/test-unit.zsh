#!/bin/zsh
# Checks of the decisions bin/cdp makes from text it does not control: which
# process the watchdog signals, which folder a name stands for, what is written
# into a launcher, what environment a profile starts with and how a build is
# signed.
#
# Runs wherever zsh does; it needs no Mac and no Claude. The functions are
# loaded from a copy of bin/cdp without its command dispatch, HOME is a
# throwaway directory, and ps, kill, sleep, open and codesign are recorders.
# No real process is listed or signalled, nothing is launched or signed.
#
#   zsh scripts/test-unit.zsh

REPO="${0:A:h:h}"
SANDBOX=${$(mktemp -d):A}
[[ -n "$SANDBOX" && -d "$SANDBOX" ]] || { print -r -- "no temporary directory"; exit 1 }
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

# Stands in for /usr/bin/open. launch_clone starts it through `env -i`, so its
# output file is written into it: no variable would reach it.
OPEN_RECORD="$SANDBOX/open.record"
OPEN_STUB="$SANDBOX/open-stub"
cat > "$OPEN_STUB" <<EOF
#!/bin/sh
{ /usr/bin/env; printf 'ARG %s\n' "\$@"; } > '$OPEN_RECORD'
EOF
chmod +x "$OPEN_STUB"

FUNCS="$SANDBOX/cdp-functions.zsh"
sed -e '/^# ---- dispatch/,$d' -e "s|/usr/bin/open -n -a|'$OPEN_STUB' -n -a|" "$REPO/bin/cdp" > "$FUNCS"
if ! grep -q '^# ---- dispatch' "$REPO/bin/cdp" || ! grep -qF "'$OPEN_STUB' -n -a" "$FUNCS" || grep -q '/usr/bin/open' "$FUNCS"; then
  print -r -- "bin/cdp no longer has the shape this test loads it by (dispatch marker, the one call to /usr/bin/open)"
  exit 1
fi

source "$FUNCS"   # sets -euo pipefail, like the script itself

pass=0; fail=0
eq() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); print -r -- "ok   $1"
  else
    fail=$((fail + 1)); print -r -- "FAIL $1"
    print -r -- "       got:  [${2//$'\n'/<NL>}]"
    print -r -- "       want: [${3//$'\n'/<NL>}]"
  fi
}
has() { [[ "$2" == *"$3"* ]] && eq "$1" yes yes || eq "$1" "$2" "…$3…" }
there() { [[ -e "$1" ]] && print yes || print no }
vis() { print -r -- "${1//$'\t'/<TAB>}" }
# Stands in for a volume that ignores letter case, where $2 would already
# name the folder $1. On such a volume the name exists and nothing is made.
alias_of() { [[ -e "$2" ]] || ln -s "$1" "$2" }

# Recorders, redefined after every `source "$FUNCS"`.
PS_LINES=()
LOG="$SANDBOX/log"
PS_ARGS="$SANDBOX/ps.args"
stubs() {
  ps() { print -r -- "$*" > "$PS_ARGS"; print -rl -- $PS_LINES }
  kill() { print -r -- "kill $*" >> "$LOG"; [[ "$1" == "-0" ]] && return 1; return 0 }
  sleep() { : }
  find_claude_app() { print -r -- "/Applications/Claude.app" }
  function /usr/bin/codesign { print -r -- "${(j:|:)@}" >> "$SANDBOX/signed" }
}
stubs

mkdir -p "$APP_SUPPORT" "$LAUNCHER_DIR" "$CLONES_DIR"
C="$CLONES_DIR"; AS="$APP_SUPPORT"

print -r -- "---- names"
eq "plain name"                          "$(slugify 'client acme')"             "client-acme"
eq "quotes and shell syntax"             "$(slugify 'a"; do shell script "id')" "a-do-shell-script-id"
eq "path traversal"                      "$(slugify '../../etc')"               "etc"
eq "a typed backslash-n stays text"      "$(slugify 'a\nb')"                    "a-nb"
eq "a line break is folded in"           "$(slugify $'a\nb')"                   "a-b"
eq "a backslash-x escape is not decoded" "$(slugify 'x\x22y')"                  "x-x22y"
eq "backslash-c does not cut the name"   "$(slugify 'a\cb')"                    "a-cb"
eq "empty"                               "$(slugify '')"                        ""
eq "display round trip"                  "$(displayify "$(slugify 'Client Acme')")" "Client Acme"

print -r -- "---- which folder a name stands for"
mkdir -p "$AS/Claude-Work Old" "$AS/Claude-Work_Old" "$AS/Claude-Work" "$AS/Claude-Solo_Odd"
eq "typed name resolves"     "$(profile_display 'work old' 2>&1)" "Work Old"
eq "folder name resolves"    "$(profile_display 'Work Old' 2>&1)" "Work Old"
out=$(profile_display 'Work_Old' 2>&1) && rc=0 || rc=$?
eq "a folder cdp would read as another profile is refused" "$rc" "1"
has "  the message names the profile it would have been read as" "$out" "the profile 'Work Old'"
out=$(profile_display 'Solo_Odd' 2>&1) && rc=0 || rc=$?
eq "a folder not spelled cdp's way is refused" "$rc" "1"
[[ "$out" != *"the profile '"* ]] && eq "  no other profile is named when there is none" yes yes ||
  eq "  no other profile is named when there is none" "$out" "<no mention>"
eq "an unknown name still resolves; the caller reports not found" "$(profile_display 'nope' 2>&1)" "Nope"
mkdir -p "$AS/Claude-x\c_y" "$AS/Claude-A"$'\n'"B_c" "$AS/Claude-Büro_Alt"
out=$(profile_display 'x\c_y' 2>&1) && rc=0 || rc=$?
[[ "$out" == *"Folder: $AS/Claude-x\c_y" ]] && eq "a backslash sequence in a name does not cut the message short" yes yes ||
  eq "a backslash sequence in a name does not cut the message short" "$out" "…Folder: $AS/Claude-x\c_y"
out=$(profile_display $'A\nB_c' 2>&1) && rc=0 || rc=$?
has "a line break in a name is shown as a placeholder" "$out" "'A?B_c'"
lines=("${(@f)out}")
eq "  and the message stays on one line" "${#lines}" "1"
out=$(LC_ALL=C profile_display 'Büro_Alt' 2>&1) && rc=0 || rc=$?
has "other characters in a name are shown as they are, in any locale" "$out" "'Büro_Alt'"
out=$(profile_display '日本語' 2>&1) && rc=0 || rc=$?
eq "a name with no letters or digits is refused" "$rc" "1"
alias_of "Claude-Work" "$AS/Claude-work"
eq "letter case alone is the same folder where the volume ignores case" "$(profile_display 'work' 2>&1)" "Work"

print -r -- "---- remove cannot delete a folder other than the one named"
( CDP_FROM_CHOOSER=1 cmd_remove 'Work_Old' --delete-data ) >/dev/null 2>&1 && rc=0 || rc=$?
eq "remove Work_Old --delete-data fails" "$rc" "1"
eq "  Claude-Work Old is still there" "$(there "$AS/Claude-Work Old")" "yes"
eq "  Claude-Work_Old is still there" "$(there "$AS/Claude-Work_Old")" "yes"
( CDP_FROM_CHOOSER=1 cmd_remove 'work old' --delete-data ) >/dev/null 2>&1 && rc=0 || rc=$?
eq "remove 'work old' --delete-data succeeds" "$rc" "0"
eq "  Claude-Work Old is deleted"    "$(there "$AS/Claude-Work Old")" "no"
eq "  Claude-Work_Old is untouched"  "$(there "$AS/Claude-Work_Old")" "yes"

print -r -- "---- a launcher names its profile by folder spelling"
mkdir -p "$AS/Claude-Client Acme" "$AS/Claude-client-acme"
compile_launcher() { cp "$1" "$SANDBOX/launcher.src"; mkdir -p "$2/Contents/Resources" }
build_launcher client-acme "Client Acme" blue /Applications/Claude.app
has "the launcher passes the display name" "$(<"$SANDBOX/launcher.src")" 'launch " & quoted form of "Client Acme" &'
eq "  which resolves next to a folder spelled like its slug" "$(profile_display 'Client Acme' 2>&1)" "Client Acme"
out=$(profile_display 'client-acme' 2>&1) && rc=0 || rc=$?
eq "  the slug, now some other folder's name, is refused" "$rc" "1"

print -r -- "---- which processes count as strays"
PS_LINES=(
  "  812 $C/Claude Work.app/Contents/MacOS/Claude"
  "48213 $C/Claude Client Acme.app/Contents/MacOS/Claude"
  "  900 $C/Claude 2024.app/Contents/MacOS/Claude"
  "  901 $C/Claude Flagged.app/Contents/MacOS/Claude --some-flag"
  "  813 $C/Claude Homed.app/Contents/MacOS/Claude --user-data-dir=$AS/Claude-Homed"
  "  814 $C/Claude Work.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
  "  815 $C/Claude Work.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler --database=/x"
  "  816 $C/Claude Work.app/Contents/MacOS/Claude /Users/x/server/index.js --stdio"
  "  817 $C/Claude Work.app/Contents/MacOS/Claude Helper --type=gpu-process"
  "51000 /bin/sleep 999 $C/Claude X\\n-1\\tWork.app/Contents/MacOS/Claude"
  "  902 /usr/bin/tail $C/Claude -1.app/Contents/MacOS/Claude"
  "  903 /usr/bin/vim $C/Claude Work.app/Contents/MacOS/Claude"
  "  904 $C/Claude Work.app/Contents/MacOS/ClaudeOther"
  "  -1 $C/Claude Work.app/Contents/MacOS/Claude"
  "abc $C/Claude Work.app/Contents/MacOS/Claude"
)
want="812"$'\t'"Work"$'\n'"48213"$'\t'"Client Acme"$'\n'"900"$'\t'"2024"$'\n'"901"$'\t'"Flagged"
eq "only a clone's main binary, bare or with flags, under its own pid" "$(stray_pids)" "$want"
eq "  from this user's processes, with whole command lines" "$(<"$PS_ARGS")" "-xww -o pid=,command="
# A process chooses its own argv[0]; all it can do with it is name itself.
PS_LINES=("  777 $C/Claude X\\n-1\\tWork.app/Contents/MacOS/Claude")
eq "escapes in a forged name make one record, with the process's own pid" "$(vis "$(stray_pids)")" "777<TAB>X\\n-1\\tWork"
PS_LINES=("  778 $C/Claude A	-1.app/Contents/MacOS/Claude")   # a real TAB in the name
eq "a TAB in a forged name cannot move the pid field" "$(vis "$(stray_pids)")" "778<TAB>A<TAB>-1"
PS_LINES=()
eq "no processes: empty" "$(stray_pids)" ""
stray_pids >/dev/null && rc=0 || rc=$?
eq "  and not a failure that would end the script" "$rc" "0"

print -r -- "---- which pids are signalled"
launch_profile() { print -r -- "launch $1" >> "$LOG" }
info() { : }
: > "$LOG"
stray_pids() {
  local p
  for p in -1 0 1 abc "" "12 34" 10000000 4294967295 4294967297 18446744073709551615 4242; do
    print -r -- "$p"$'\t'"Work"
  done
}
adopt_strays
eq "only an ordinary pid" "$(<"$LOG")" "kill -TERM 4242"$'\n'"kill -0 4242"$'\n'"kill -0 4242"$'\n'"launch Work"
source "$FUNCS"; stubs
launch_profile() { print -r -- "launch $1" >> "$LOG" }
info() { : }
: > "$LOG"
PS_LINES=(
  "51000 /bin/sleep 999 $C/Claude X\\n-1\\tWork.app/Contents/MacOS/Claude"
  "  902 /usr/bin/tail $C/Claude -1.app/Contents/MacOS/Claude"
  "  812 $C/Claude Work.app/Contents/MacOS/Claude"
)
adopt_strays
eq "end to end: crafted lines ignored, the real stray re-homed" "$(<"$LOG")" "kill -TERM 812"$'\n'"kill -0 812"$'\n'"kill -0 812"$'\n'"launch Work"

print -r -- "---- which process is a profile's running instance"
W="$AS/Claude-Work"; W2="$AS/Claude-Work Two"
PS_LINES=(
  "  640 $C/Claude Work Two.app/Contents/MacOS/Claude --user-data-dir=$W2"
  "  641 $C/Claude Work Two.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer --user-data-dir=$W2"
)
eq "Work is not running when only Work Two is"    "$(instance_pid "$W")"  ""
eq "Work Two: the main process, not its helper"   "$(instance_pid "$W2")" "640"
eq "  from this user's processes, with whole command lines" "$(<"$PS_ARGS")" "-xww -o pid=,command="
PS_LINES+=("48000 $C/Claude Work.app/Contents/MacOS/Claude --user-data-dir=$W")
eq "Work is found once it runs"                   "$(instance_pid "$W")"  "48000"
eq "Work Two keeps its own pid"                   "$(instance_pid "$W2")" "640"
PS_LINES=("   77 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=$W --enable-logging")
eq "a following flag still matches"               "$(instance_pid "$W")"  "77"
PS_LINES=("   78 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=$W   ")
eq "trailing blanks still match"                  "$(instance_pid "$W")"  "78"
PS_LINES=(
  "   79 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=$W"
  "   80 /Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=$W"
)
eq "the first match only"                         "$(instance_pid "$W")"  "79"
PS_LINES=()
eq "nothing running: empty" "$(instance_pid "$W")" ""
instance_pid "$W" >/dev/null && rc=0 || rc=$?
eq "  and not a failure that would end the script" "$rc" "0"

print -r -- "---- which launchers an update rebuilds"
evil='Evil" & (do shell script "id") & "'
mkdir -p "$AS/Claude-$evil" "$LAUNCHER_DIR/Claude $evil.app" \
         "$LAUNCHER_DIR/Claude Work.app" "$LAUNCHER_DIR/Claude Work_Old.app" \
         "$AS/Claude-A"$'\n'"B" "$LAUNCHER_DIR/Claude A"$'\n'"B.app" \
         "$AS/Claude-No Launcher" \
         "$AS/Claude-qa" "$LAUNCHER_DIR/Claude Qa.app"
alias_of "Claude-qa" "$AS/Claude-Qa"
alias_of "Claude Qa.app" "$LAUNCHER_DIR/Claude qa.app"
rm -rf "$LAUNCHER_DIR/Claude Client Acme.app"
build_launcher() { print -r -- "build [$1] [$2]" >> "$SANDBOX/built" }
install_watchdog() { : }
ensure_tint_tool() { print -r -- "/dev/null" }
manager_app() { return 1 }
cached="$CACHE_DIR/$HELPER_NAME.app"
mkdir -p "$cached/Contents/MacOS"; : > "$cached/Contents/MacOS/stale"
: > "$SANDBOX/built"
warned=$(sync_install 2>&1 >/dev/null)
# Sorted here: the order sync_install walks the folders in follows the locale.
eq "profiles with a launcher, in cdp's spelling; nothing else" "$(LC_ALL=C sort "$SANDBOX/built")" "build [qa] [Qa]"$'\n'"build [work] [Work]"
has "a skipped folder that has a launcher is reported" "$warned" "Launcher not updated: the folder 'Work_Old'"
eq "no manager app with a helper: the cached helper is kept" "$(there "$cached/Contents/MacOS/stale")" "yes"
mgr="$SANDBOX/Claude Profiles.app"
mkdir -p "$mgr/Contents/Resources/$HELPER_NAME.app/Contents/MacOS"
: > "$mgr/Contents/Resources/$HELPER_NAME.app/Contents/MacOS/$HELPER_NAME"
chmod +x "$mgr/Contents/Resources/$HELPER_NAME.app/Contents/MacOS/$HELPER_NAME"
manager_app() { print -r -- "$mgr" }
sync_install >/dev/null 2>&1
eq "the manager app ships a helper: the cached one is dropped" "$(there "$cached")" "no"

print -r -- "---- a refused name launches nothing"
source "$FUNCS"; stubs
ensure_clone() { print -r -- "ensure_clone" >> "$LOG" }
launch_clone() { print -r -- "launch_clone" >> "$LOG" }
: > "$LOG"
( launch_profile 'Work_Old' || true ) 2>/dev/null
eq "refused inside '|| true': nothing is reached" "$(<"$LOG")" ""
( launch_profile 'Client Acme' ) 2>/dev/null && rc=0 || rc=$?
eq "a launcher's own name reaches the launch" "$(<"$LOG")" "ensure_clone"$'\n'"launch_clone"

print -r -- "---- the environment a profile starts with"
source "$FUNCS"; stubs
clone="$C/Claude Work.app"
mkdir -p "$clone/Contents/MacOS"; : > "$clone/Contents/MacOS/Claude"; chmod +x "$clone/Contents/MacOS/Claude"
# The names the recording shell adds to its own environment are not cdp's.
env_names() { grep -v '^ARG ' "$OPEN_RECORD" | cut -d= -f1 | grep -vxE 'PWD|OLDPWD|SHLVL|_' | sort | tr '\n' ' ' }
( export SECRET_API_KEY=leak HTTPS_PROXY=http://proxy NODE_OPTIONS=--inspect ELECTRON_RUN_AS_NODE=1 \
         CLAUDE_CONFIG_DIR=/wrong SSH_AUTH_SOCK='/tmp/agent dir/*.sock' USER=tester SHELL=/bin/zsh LANG=en_US.UTF-8
  launch_clone "$clone" "$W" ) 2>/dev/null
eq "only the listed variables reach open" "$(env_names)" "HOME LANG LOGNAME PATH SHELL SSH_AUTH_SOCK TMPDIR USER "
eq "  the agent socket stays one word" "$(grep '^SSH_AUTH_SOCK=' "$OPEN_RECORD")" "SSH_AUTH_SOCK=/tmp/agent dir/*.sock"
args=(${(f)"$(sed -n 's/^ARG //p' "$OPEN_RECORD")"})
eq "  open gets the clone, the config dir and the data dir" "${(j:|:)args}" "-n|-a|$clone|--env|CLAUDE_CONFIG_DIR=$W/claude-config|--args|--user-data-dir=$W"
rm -f "$OPEN_RECORD"
( unset USER SSH_AUTH_SOCK; source "$FUNCS"; launch_clone "$clone" "$W" ) 2>/dev/null && rc=0 || rc=$?
eq "USER missing from the environment: the launch still happens" "$rc $(there "$OPEN_RECORD")" "0 yes"
eq "  with the user's name, and no empty agent socket" "$(grep -cE '^(USER|LOGNAME)=.+' "$OPEN_RECORD") $(grep -c '^SSH_AUTH_SOCK' "$OPEN_RECORD")" "2 0"

print -r -- "---- how a build is signed"
source "$FUNCS"; stubs
SCRIPT_PATH="$REPO/bin/cdp"
swiftc() { : }
swift_compile() { : > "$1" }
build_helper() { mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources" }
info() { : }
B="$SANDBOX/out/Claude Profiles.app"; H="$B/Contents/Resources/$HELPER_NAME.app"
id='Developer ID Application: Example Org (ABCDE12345)'
: > "$SANDBOX/signed"; ( unset CDP_SIGN_IDENTITY; build_manager_app "$B" )
eq "no identity: ad hoc, the helper before the app that seals it" "$(<"$SANDBOX/signed")" "--force|--sign|-|$H"$'\n'"--force|--sign|-|$B"
: > "$SANDBOX/signed"; ( export CDP_SIGN_IDENTITY=-; build_manager_app "$B" )
eq "'-' is ad hoc too" "$(<"$SANDBOX/signed")" "--force|--sign|-|$H"$'\n'"--force|--sign|-|$B"
: > "$SANDBOX/signed"; ( export CDP_SIGN_IDENTITY="$id"; build_manager_app "$B" )
eq "an identity: one word, hardened runtime and timestamp, on both" "$(<"$SANDBOX/signed")" \
  "--force|--sign|$id|--options|runtime|--timestamp|$H"$'\n'"--force|--sign|$id|--options|runtime|--timestamp|$B"
eq "the build carries this script" "$(cmp -s "$REPO/bin/cdp" "$B/Contents/Resources/cdp" && print same || print differs)" "same"

print -r -- ""
print -r -- "passed=$pass failed=$fail"
(( fail == 0 ))
