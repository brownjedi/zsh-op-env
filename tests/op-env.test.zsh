# Sourced by tests/run.zsh. Every test_* function runs in its own subshell.

# Sent through op inject or op read; each value must come back byte-for-byte.
typeset -gA VERBATIM=(
    op://Dev/v/equals    'a=b=c'
    op://Dev/v/multiline $'line1\nline2'
    op://Dev/v/trailing  $'trailing\n\n'
    op://Dev/v/leading   $'\n\nleading'
    op://Dev/v/pem       $'-----BEGIN KEY-----\nabc\n-----END KEY-----\n'
    op://Dev/v/spaces    '  spaced  '
    op://Dev/v/meta      'back\slash $HOME $(id) `id` "q" '\''q'\'
    op://Dev/v/braces    '{{ not a template }}'
    op://Dev/v/otherref  'see op://Dev/other/ref'
    op://Dev/v/digit     '2'
    op://Dev/v/empty     ''
)

export_verbatim() {
    local ref
    integer i=0
    for ref in ${(ok)VERBATIM}; do
        secret $ref "$VERBATIM[$ref]"
        export V$(( ++i ))=$ref
    done
}

assert_verbatim() {
    local ref
    integer i=0
    for ref in ${(ok)VERBATIM}; do
        assert_eq "$VERBATIM[$ref]" "${(P)${:-V$(( ++i ))}}" $ref
    done
}

test_no_refs_makes_no_op_call() {
    export PLAIN=value
    run op-env-resolve
    assert_status 0
    assert_calls
}

test_resolves_ref_in_place_via_inject() {
    secret op://Dev/db/url 'postgres://u:p@h/db'
    export DB=op://Dev/db/url
    run op-env-resolve
    assert_status 0
    assert_eq 'postgres://u:p@h/db' $DB
    assert_contains ${parameters[DB]} export
    assert_eq '' "$(<$T/err)" stderr
    assert_calls 'inject op://Dev/db/url'
}

test_batches_refs_into_one_inject_and_dedupes() {
    secret op://Dev/a/x one
    secret op://Dev/b/x two
    export A=op://Dev/a/x B=op://Dev/b/x C=op://Dev/a/x
    run op-env-resolve
    assert_status 0
    assert_eq one $A
    assert_eq two $B
    assert_eq one $C
    assert_calls 'inject op://Dev/a/x op://Dev/b/x'
}

test_values_round_trip_via_inject() {
    export_verbatim
    run op-env-resolve
    assert_status 0
    assert_verbatim
    local -a calls=("${(@f)$(<$T/calls)}")
    assert_eq 1 $#calls 'number of op calls'
}

test_values_round_trip_via_read() {
    export FAKE_OP_INJECT=fail
    export_verbatim
    run op-env-resolve
    assert_status 0
    assert_verbatim
}

test_bad_ref_does_not_block_others() {
    secret op://Dev/a/x good
    export GOOD=op://Dev/a/x BAD=op://Dev/missing/x
    run op-env-resolve
    assert_status 1
    assert_eq good $GOOD
    assert_eq op://Dev/missing/x $BAD
    assert_calls 'inject op://Dev/missing/x op://Dev/a/x' 'read op://Dev/missing/x' 'read op://Dev/a/x'
    local err=$(<$T/err)
    assert_contains $err 'could not resolve BAD (still set to their op:// refs)'
    assert_contains $err 'could not find item'
    assert_contains $err 'op inject: [ERROR]'
    assert_not_contains $err GOOD
}

test_signed_out_stops_after_first_read() {
    export FAKE_OP_INJECT=signed-out FAKE_OP_READ=signed-out
    secret op://Dev/a/x one
    secret op://Dev/b/x two
    export A=op://Dev/a/x B=op://Dev/b/x
    run op-env-resolve
    assert_status 1
    assert_eq op://Dev/a/x $A
    assert_eq op://Dev/b/x $B
    assert_calls 'inject op://Dev/a/x op://Dev/b/x' 'read op://Dev/a/x'
    local err=$(<$T/err)
    assert_contains $err 'could not resolve A, B'
    assert_contains $err 'skipped after op://Dev/a/x failed: [ERROR]'
    assert_contains $err 'not currently signed in'
}

test_interrupted_inject_skips_reads() {
    export FAKE_OP_INJECT=interrupt
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    assert_status 1
    assert_eq op://Dev/a/x $A
    assert_calls 'inject op://Dev/a/x'
    assert_contains "$(<$T/err)" 'op inject interrupted (exit 130)'
}

test_interrupted_read_skips_remaining_reads() {
    export FAKE_OP_INJECT=fail FAKE_OP_READ=interrupt
    export A=op://Dev/a/x B=op://Dev/b/x
    run op-env-resolve
    assert_status 1
    assert_calls 'inject op://Dev/a/x op://Dev/b/x' 'read op://Dev/a/x'
}

test_unresolved_template_falls_back_to_read() {
    export FAKE_OP_INJECT=passthrough
    secret op://Dev/a/x one
    export A=op://Dev/a/x B=op://Dev/missing/x
    run op-env-resolve
    assert_status 1
    assert_eq one $A
    assert_eq op://Dev/missing/x $B
    assert_calls 'inject op://Dev/a/x op://Dev/missing/x' 'read op://Dev/missing/x'
}

test_missing_op_binary() {
    path=(${path:#$TESTS/bin})
    export A=op://Dev/a/x
    run op-env-resolve
    assert_status 1
    assert_eq op://Dev/a/x $A
    assert_contains "$(<$T/err)" '`op` not found in PATH'
    assert_calls
}

test_caches_resolved_values() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    clear_calls
    clear_secrets
    # direnv re-exports the ref on every cd back into the directory.
    export A=op://Dev/a/x
    run op-env-resolve
    assert_status 0
    assert_eq one $A
    assert_calls
}

test_no_cache_asks_op_every_pass() {
    export OP_ENV_NO_CACHE=1
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    assert_eq 0 ${#_OP_ENV_CACHE} 'cache size'
    clear_calls
    export A=op://Dev/a/x
    run op-env-resolve
    assert_status 0
    assert_eq one $A
    assert_calls 'inject op://Dev/a/x'
}

test_no_cache_bypasses_values_cached_earlier() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    clear_calls
    export OP_ENV_NO_CACHE=1 A=op://Dev/a/x
    run op-env-resolve
    assert_eq one $A
    assert_calls 'inject op://Dev/a/x'
}

test_flush_drops_cache() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    run op-env-flush
    assert_eq 'op-env: cache cleared' "$(<$T/out)" stdout
    assert_eq 0 ${#_OP_ENV_CACHE} 'cache size'
    assert_eq one $A
    clear_calls
    export A=op://Dev/a/x
    run op-env-resolve
    assert_eq one $A
    assert_calls 'inject op://Dev/a/x'
}

test_failure_is_reported_once() {
    export A=op://Dev/missing/x
    run op-env-resolve
    assert_contains "$(<$T/err)" 'could not resolve A'
    run op-env-resolve
    assert_status 1
    assert_eq '' "$(<$T/err)" stderr
}

test_if_changed_skips_refs_that_already_failed() {
    export A=op://Dev/missing/x
    run _op-env-preexec
    assert_status 0
    assert_calls 'inject op://Dev/missing/x' 'read op://Dev/missing/x'
    clear_calls
    run _op-env-preexec
    assert_calls
    secret op://Dev/b/x two
    export B=op://Dev/b/x
    run _op-env-preexec
    assert_eq two $B
    assert_calls 'inject op://Dev/missing/x op://Dev/b/x' 'read op://Dev/missing/x' 'read op://Dev/b/x'
}

test_forced_pass_retries_refs_that_already_failed() {
    export A=op://Dev/missing/x
    run _op-env-preexec
    secret op://Dev/missing/x found
    run op-env-resolve
    assert_status 0
    assert_eq found $A
}

test_rewarns_after_ref_recovers_and_breaks_again() {
    export OP_ENV_NO_CACHE=1
    export A=op://Dev/a/x
    run op-env-resolve
    assert_contains "$(<$T/err)" 'could not resolve A'
    secret op://Dev/a/x one
    run op-env-resolve
    assert_eq one $A
    clear_secrets
    export A=op://Dev/a/x
    run op-env-resolve
    assert_status 1
    assert_contains "$(<$T/err)" 'could not resolve A'
}

test_vault_allowlist_refuses_other_vaults() {
    export OP_ENV_VAULTS=' Dev , Staging '
    secret op://Dev/a/x dev
    secret op://Staging/a/x staging
    secret op://Private/bank/password hunter2
    export A=op://Dev/a/x B=op://Private/bank/password C=op://Staging/a/x
    run op-env-resolve
    assert_status 1
    assert_eq dev $A
    assert_eq op://Private/bank/password $B
    assert_eq staging $C
    assert_not_contains "$(<$T/calls)" Private
    assert_contains "$(<$T/err)" 'vault "Private" is not in OP_ENV_VAULTS'
}

test_vault_allowlist_is_exact_and_case_sensitive() {
    export OP_ENV_VAULTS=Dev
    export A=op://dev/a/x B=op://Dev2/a/x
    run op-env-resolve
    assert_status 1
    assert_eq op://dev/a/x $A
    assert_eq op://Dev2/a/x $B
    assert_calls
}

test_vault_allowlist_applies_to_cached_values() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    export OP_ENV_VAULTS=Staging A=op://Dev/a/x
    run op-env-resolve
    assert_status 1
    assert_eq op://Dev/a/x $A
}

test_ignores_non_candidates() {
    secret op://Dev/a/x one
    typeset -g NOT_EXPORTED=op://Dev/a/x
    typeset -grx READONLY=op://Dev/a/x
    typeset -gax ARRAY=(op://Dev/a/x)
    export BARE=op:// PREFIXED=' op://Dev/a/x' OTHER=https://example.com
    run op-env-resolve
    assert_status 0
    assert_eq op://Dev/a/x $NOT_EXPORTED
    assert_eq op://Dev/a/x $READONLY
    assert_eq op://Dev/a/x "$ARRAY"
    assert_eq op:// $BARE
    assert_eq ' op://Dev/a/x' $PREFIXED
    assert_calls
}

test_debug_trace_omits_secret_values() {
    secret op://Dev/a/x 's3cr3t-inject'
    secret op://Dev/b/x 's3cr3t-read'
    export A=op://Dev/a/x
    run op-env-resolve --debug
    local err=$(<$T/err)
    assert_contains $err 'op-env: found 1 ref(s): A'
    assert_contains $err 'via inject'
    assert_not_contains $err s3cr3t
    export FAKE_OP_INJECT=fail B=op://Dev/b/x
    run op-env-resolve --debug
    err=$(<$T/err)
    assert_contains $err 'via op read'
    assert_not_contains $err s3cr3t
    assert_eq '' "${OP_ENV_DEBUG:-}" 'OP_ENV_DEBUG after --debug'
}

test_xtrace_does_not_leak_secrets() {
    secret op://Dev/a/x 's3cr3t-forced'
    secret op://Dev/b/x 's3cr3t-hook'
    export A=op://Dev/a/x
    setopt xtrace
    op-env-resolve 2>$T/err
    export B=op://Dev/b/x
    _op-env-preexec 2>>$T/err
    unsetopt xtrace
    assert_eq s3cr3t-forced $A
    assert_eq s3cr3t-hook $B
    assert_not_contains "$(<$T/err)" s3cr3t
}

test_resolve_cli_options() {
    run op-env-resolve --help
    assert_status 0
    assert_contains "$(<$T/out)" 'usage: op-env-resolve'
    run op-env-resolve --bogus
    assert_status 2
    assert_eq 'op-env-resolve: unknown option: --bogus' "$(<$T/err)" stderr
}

# Commands come from stdin. No ZLE, or zsh reads from the terminal instead; no prompt, or it is drawn on the terminal.
interactive_zsh() {
    PS1= zsh -fi +Z +o prompt_cr +o prompt_sp 2>/dev/null
}

test_hook_only_in_interactive_shells() {
    assert_eq '' "${preexec_functions[(r)_op-env-preexec]}" 'preexec hook when non-interactive'
    local src="source ${(qq)ROOT}/op-env.plugin.zsh; source ${(qq)ROOT}/op-env.plugin.zsh"
    assert_eq _op-env-preexec "$(print -r -- "$src; print -r -- \$preexec_functions" | interactive_zsh)" \
        'preexec hooks when interactive'
    assert_eq '' "$(print -r -- "OP_ENV_DISABLE_HOOK=1 $src; print -r -- \$preexec_functions" | interactive_zsh)" \
        'preexec hooks with OP_ENV_DISABLE_HOOK'
}

test_hook_resolves_refs_exported_by_precmd() {
    secret op://Dev/a/x one
    # Stands in for direnv, which exports from a precmd hook.
    local script="source ${(qq)ROOT}/op-env.plugin.zsh
precmd() { export A=op://Dev/a/x }
print -r -- \"A=\$A\""
    assert_eq A=one "$(print -r -- $script | interactive_zsh)" 'output of interactive shell'
}
