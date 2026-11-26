#!/usr/bin/env bash
# ci/lib.sh: helpers the hosted workflows share. Sourced, not run: a step sources it after the checkout, from the
# peeryard root (`source ci/lib.sh`), or from the workspace when peeryard is checked out under peeryard/
# (`source peeryard/ci/lib.sh`: only is_idlike is safe there; build and stack call diffrun/ and patches/ by relative path).
# It sets no shell options: the step's own shell (bash -e -o pipefail on a hosted runner) applies.
#
#   build <diffrun/build.sh args...>    one retry; prints the jar path, or returns 1 after two failed attempts
#   stack <patches/stack.sh args...>    the same for a patch stack
#   need_jar <var> <message> <build|stack> <args...>
#                                       sets <var> to the jar that build or stack printed; when it failed, prints
#                                       ::error::<message> and exits the step (exit 1)
#   is_idlike <string>                  true when the string reads as a private tracking id
#
# Why need_jar: a failed build prints nothing, and `cp "" out/x.jar` would fail with a message that does not say which
# build it was; each jar is checked before it is copied, under its own error line.

# _ci_jar <what> <command...>: run the command up to twice; its last stdout line, when that names a file, is the jar.
# A cold sbt build can lose one dependency download to a transient repository error: hence the one retry, 20 s apart.
_ci_jar(){
  local what="$1" j attempt; shift
  for attempt in 1 2; do
    j="$("$@" | tail -1)" && [ -f "$j" ] && { echo "$j"; return 0; }
    echo "$what failed (attempt $attempt)" >&2; sleep 20
  done
  return 1
}
build(){ _ci_jar build bash diffrun/build.sh "$@"; }
stack(){ _ci_jar "stack $*" bash patches/stack.sh "$@"; }

need_jar(){
  local _need_jar_var="$1" _need_jar_msg="$2" _need_jar_out; shift 2
  _need_jar_out="$("$@")" || { echo "::error::$_need_jar_msg"; exit 1; }
  printf -v "$_need_jar_var" '%s' "$_need_jar_out"
}

# A letter of [abceklmprsx] (either case), an optional dash and exactly three digits, not inside a longer word or number,
# reads as a private tracking id; labels, arm names and run names are public, so the workflows refuse them.
# Descriptive labels (pr2784-base, v609, arm) pass. No nocasematch: both cases are spelled out.
CI_IDLIKE='(^|[^A-Za-z0-9])[AaBbCcEeKkLlMmPpRrSsXx]-?[0-9]{3}([^0-9]|$)'
is_idlike(){ [[ "$1" =~ $CI_IDLIKE ]]; }
