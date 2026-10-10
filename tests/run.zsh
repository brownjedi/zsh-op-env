#!/usr/bin/env zsh
# zsh tests/run.zsh [name-substring]
# Each test runs in its own subshell with a fresh plugin load and the fake `op` from tests/bin.

# Clean environment, so op:// refs exported in the caller's shell cannot leak in.
[[ -n ${_OP_ENV_TEST_CLEAN:-} ]] || exec env -i _OP_ENV_TEST_CLEAN=1 HOME=$HOME PATH=$PATH zsh -f -- ${0:A} "$@"

emulate zsh
typeset -g TESTS=${0:A:h} ROOT=${0:A:h:h} T
typeset -gi st passed failed

fail() {
    print -ru2 -- "  $1"
    exit 1
}

assert_eq() {
    [[ $2 == "$1" ]] || fail "${3:-value}: expected ${(qqqq)1}, got ${(qqqq)2}"
}

assert_status() {
    assert_eq $1 $st 'exit status'
}

assert_contains() {
    [[ $1 == *"$2"* ]] || fail "expected ${(qqqq)1} to contain ${(qqqq)2}"
}

assert_not_contains() {
    [[ $1 != *"$2"* ]] || fail "expected ${(qqqq)1} not to contain ${(qqqq)2}"
}

assert_calls() {
    assert_eq "${(F)@}" "$(<$T/calls)" 'op calls'
}

secret() {
    print -r -- "secrets+=(${(qq)1} ${(qq)2})" >>$T/secrets.zsh
}

clear_secrets() {
    : >$T/secrets.zsh
}

clear_calls() {
    : >$T/calls
}

# Runs in this shell, not $(...), so exports made by the command stick.
run() {
    "$@" >$T/out 2>$T/err
    st=$?
}

setup_test() {
    export FAKE_OP_DIR=$T
    path=($TESTS/bin ${commands[zsh]:h} /usr/bin /bin)
    source $ROOT/op-env.plugin.zsh
}

source $TESTS/op-env.test.zsh

for t in ${(ok)functions[(I)test_*]}; do
    [[ -n $1 && $t != *$1* ]] && continue
    T=$(mktemp -d)
    : >$T/secrets.zsh
    : >$T/calls
    if ( setup_test; $t ) 2>$T/log; then
        print -r -- "ok   $t"
        (( passed++ ))
    else
        print -r -- "FAIL $t"
        print -r -- "$(<$T/log)"
        (( failed++ ))
    fi
    rm -rf -- $T
done

print -r -- "$passed passed, $failed failed"
(( passed && ! failed ))
