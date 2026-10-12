# Sourced by tests/run.zsh. Every test_* function runs in its own subshell.

# Sent through op inject or op read; each value must come back byte-for-byte.
typeset -gA VERBATIM=(
    op://Dev/v/equals    'a=b=c'
    op://Dev/v/multiline $'line1\nline2'
    op://Dev/v/trailing  $'trailing\n\n'
    op://Dev/v/leading   $'\n\nleading'
    op://Dev/v/pem       $'-----BEGIN KEY-----\nabc\n-----END KEY-----\n'
    op://Dev/v/pemrsa    $'-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun\nVTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u+qKhbwKfBstIs+bMY2Zkp18gnTxK\nab==\n-----END RSA PRIVATE KEY-----\n'
    op://Dev/v/pemcrlf   $'-----BEGIN KEY-----\r\nabc\r\n-----END KEY-----\r\n'
    op://Dev/v/sajson    '{"type":"service_account","project_id":"p","private_key":"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkq\n-----END PRIVATE KEY-----\n","client_email":"sa@p.iam.gserviceaccount.com"}'
    op://Dev/v/sajsonpp  $'{\n  "type": "service_account",\n  "private_key": "-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkq\\n-----END PRIVATE KEY-----\\n",\n  "note": "{{ not a template }}"\n}\n'
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
    assert_contains $err 'could not resolve BAD (left unchanged)'
    assert_contains $err 'could not find item'
    assert_contains $err 'op inject: [ERROR]'
    assert_not_contains $err GOOD
}

test_per_ref_read_errors_do_not_stop_other_reads() {
    export FAKE_OP_INJECT=fail A=op://Dev/a/x B=op://Dev/b/x
    # op 2.39's wording for a reference that is wrong on its own.
    local -a errors=(
        '"x" isn'\''t an item. Specify the item with its UUID, name, or domain.'
        '"f" isn'\''t a field in the "x" item'
        '"V" isn'\''t a vault in this account. Specify the vault with its UUID or name.'
        "invalid secret reference 'op://Dev/a': too few segments"
        'More than one item matches "x". Try again and specify the item by its ID'
        'could not find item x in vault Dev'
        'could not find field or file f in section s on item x in vault Dev'
        'no item matched the secret reference query'
        "item 'Dev/x' does not have a field 'f'"
        'item is not in an active state'
    )
    local e
    for e in $errors; do
        clear_calls
        FAKE_OP_READ_ERROR=$e run op-env-resolve
        assert_status 1
        assert_calls 'inject op://Dev/a/x op://Dev/b/x' 'read op://Dev/a/x' 'read op://Dev/b/x'
    done
}

test_session_read_error_stops_after_first_read() {
    export FAKE_OP_INJECT=fail FAKE_OP_READ_ERROR='could not find session token for account x' \
        A=op://Dev/a/x B=op://Dev/b/x
    run op-env-resolve
    assert_status 1
    assert_calls 'inject op://Dev/a/x op://Dev/b/x' 'read op://Dev/a/x'
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
    export OP_ENV_HOOK=always A=op://Dev/missing/x
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

test_vault_allowlist_naming_no_vault_refuses_every_ref() {
    secret op://Dev/a/x dev
    export OP_ENV_VAULTS=' , ' A=op://Dev/a/x
    run op-env-resolve
    assert_status 1
    assert_eq op://Dev/a/x $A
    assert_contains "$(<$T/err)" 'vault "Dev" is not in OP_ENV_VAULTS'
    assert_calls
}

test_empty_vault_allowlist_means_any_vault() {
    secret op://Dev/a/x dev
    export OP_ENV_VAULTS= A=op://Dev/a/x
    run op-env-resolve
    assert_status 0
    assert_eq dev $A
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

test_vault_allowlist_cannot_be_bypassed_through_template_syntax() {
    export OP_ENV_VAULTS=Dev
    secret op://Dev/a/x dev
    secret op://Private/bank/password hunter2
    local -a smuggled=(
        'op://Dev/a/x }}{{ op://Private/bank/password'
        $'op://Dev/a/x }}\nop://Private/bank/password\n{{ op://Dev/a/x'
        'op://Dev/a/${VAULT}'
        'x={{ op://Dev/a/${VAULT} }}'
        $'x={{ op://Dev/a/x\nop://Private/bank/password }}'
        'x={{ op://Dev/a/{{ op://Private/bank/password }} }}'
    )
    export A=op://Dev/a/x B=$smuggled[1] C=$smuggled[2] D=$smuggled[3] E=$smuggled[4] F=$smuggled[5] G=$smuggled[6]
    run op-env-resolve
    assert_status 1
    assert_eq dev $A
    assert_eq $smuggled[1] $B
    assert_eq $smuggled[2] $C
    assert_eq $smuggled[3] $D
    assert_eq $smuggled[4] $E
    assert_eq $smuggled[5] $F
    assert_eq $smuggled[6] $G
    assert_calls 'inject op://Dev/a/x'
    assert_contains "$(<$T/err)" 'not allowed in a reference'
}

test_resolves_tags_inside_a_value() {
    secret op://Dev/db/host db.internal
    secret op://Dev/db/user u
    secret op://Dev/db/pass p
    export HOST=op://Dev/db/host \
        ADDR='{{ op://Dev/db/host }}:8080' \
        URL='postgres://{{op://Dev/db/user}}:{{  op://Dev/db/pass  }}@{{ op://Dev/db/host }}/db'
    run op-env-resolve
    assert_status 0
    assert_eq db.internal $HOST
    assert_eq db.internal:8080 $ADDR
    assert_eq postgres://u:p@db.internal/db $URL
    assert_calls 'inject op://Dev/db/host op://Dev/db/user op://Dev/db/pass'
}

test_tag_wrapping_another_tag_is_refused() {
    secret op://Dev/a/x one
    local -a tmpls=(
        'x={{ op://Dev/{{ x }}/f }}'
        'x={{ op://Dev/a/x {{ }}'
        '{{ op://Dev/a/x {{ op://Dev/a/x }}'
    )
    export A=$tmpls[1] B=$tmpls[2] C=$tmpls[3]
    run op-env-resolve
    assert_status 1
    assert_eq $tmpls[1] $A
    assert_eq $tmpls[2] $B
    assert_eq $tmpls[3] $C
    assert_calls
    assert_contains "$(<$T/err)" 'could not resolve A, B, C'
    assert_contains "$(<$T/err)" 'nested {{ }} tags are not supported'
}

test_text_outside_tags_is_kept_verbatim() {
    secret op://Dev/a/x one
    local tmpl='op://Private/b/c }} {{ op://Dev/a/x }} {{ not a ref }} {{op:// }} $HOME {{ op://Dev/a/x }}'
    export A=$tmpl
    run op-env-resolve
    assert_status 0
    assert_eq 'op://Private/b/c }} one {{ not a ref }} {{op:// }} $HOME one' $A
    assert_calls 'inject op://Dev/a/x'
}

test_tag_values_round_trip() {
    local ref
    integer i=0
    for ref in ${(ok)VERBATIM}; do
        secret $ref "$VERBATIM[$ref]"
        export V$(( ++i ))="<{{ $ref }}>"
    done
    run op-env-resolve
    assert_status 0
    i=0
    for ref in ${(ok)VERBATIM}; do
        assert_eq "<$VERBATIM[$ref]>" "${(P)${:-V$(( ++i ))}}" $ref
    done
}

test_tags_resolve_all_or_nothing() {
    secret op://Dev/a/x one
    local tmpl='{{ op://Dev/a/x }}:{{ op://Dev/missing/x }}'
    export A=$tmpl
    run op-env-resolve
    assert_status 1
    assert_eq $tmpl $A
    assert_contains "$(<$T/err)" 'op-env: could not resolve A'
    assert_contains "$(<$T/err)" '  A  op://Dev/missing/x'
    assert_not_contains "$(<$T/err)" '  A  op://Dev/a/x'
}

test_nested_tags_fail_like_op_inject() {
    secret op://Dev/name/x item
    secret op://Dev/item/f deep
    local tmpl='x={{ op://Dev/{{ op://Dev/name/x }}/f }}'
    export A=$tmpl B=op://Dev/name/x
    run op-env-resolve
    assert_status 1
    assert_eq $tmpl $A
    assert_eq item $B
    assert_calls 'inject op://Dev/name/x'
    assert_contains "$(<$T/err)" 'nested {{ }} tags are not supported'
}

test_tags_obey_vault_checks() {
    export OP_ENV_VAULTS=Dev
    secret op://Dev/a/x dev
    secret op://Private/bank/password hunter2
    local tmpl='{{ op://Dev/a/x }}{{ op://Private/bank/password }}'
    export A=$tmpl
    run op-env-resolve
    assert_status 1
    assert_eq $tmpl $A
    assert_not_contains "$(<$T/calls)" Private
    assert_contains "$(<$T/err)" 'vault "Private" is not in OP_ENV_VAULTS'
}

test_resolved_secret_holding_refs_is_not_resolved_again() {
    secret op://Dev/a/x '{{ op://Dev/c/x }}'
    secret op://Dev/b/x op://Dev/c/x
    secret op://Dev/c/x other-secret
    export A=op://Dev/a/x B=op://Dev/b/x
    run op-env-resolve
    run op-env-resolve
    OP_ENV_HOOK=always run _op-env-preexec
    assert_status 0
    assert_eq '{{ op://Dev/c/x }}' $A
    assert_eq op://Dev/c/x $B
    assert_calls 'inject op://Dev/a/x op://Dev/b/x'
}

nested_zsh() {
    zsh -f -c "source ${(qq)ROOT}/op-env.plugin.zsh; $1"
}

test_nested_shell_does_not_resolve_inherited_secrets() {
    secret op://Dev/a/x 'tok-{{ op://Dev/c/x }}'
    secret op://Dev/b/x op://Dev/c/x
    secret op://Dev/c/x other-secret
    export A=op://Dev/a/x B=op://Dev/b/x
    run op-env-resolve
    clear_calls
    assert_eq 'st=0 A=tok-{{ op://Dev/c/x }} B=op://Dev/c/x' \
        "$(nested_zsh 'op-env-resolve; print -r -- "st=$? A=$A B=$B"')"
    assert_calls
}

test_nested_shell_resolves_refs_exported_after_the_last_pass() {
    secret op://Dev/a/x one
    secret op://Dev/b/x two
    export A=op://Dev/a/x
    run op-env-resolve
    # Typed on the same line as `zsh`, so no pass ran in between.
    export A=op://Dev/b/x
    assert_eq A=two "$(nested_zsh 'op-env-resolve; print -r -- "A=$A"')"
}

test_nested_shell_resolves_refs_the_parent_could_not() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run op-env-resolve
    export A=op://Dev/b/x
    run op-env-resolve
    assert_status 1
    secret op://Dev/b/x two
    assert_eq A=two "$(nested_zsh 'op-env-resolve; print -r -- "A=$A"')"
}

test_nested_shell_ignores_unsafe_inherited_names() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x _OP_ENV_RESOLVED_VARS="A:13 B[\$(touch $T/pwned)]:1"
    assert_eq A=one "$(nested_zsh 'op-env-resolve; print -r -- "A=$A"')"
    [[ ! -e $T/pwned ]] || fail 'inherited name was evaluated'
}

test_direnv_hook_catches_template_reload_within_one_command() {
    secret op://Dev/a/x one
    export DIRENV_DIFF=d1 A='{{ op://Dev/a/x }}:8080'
    run _op-env-preexec
    assert_eq one:8080 $A
    export A='{{ op://Dev/a/x }}:8080'
    run _op-env-preexec
    assert_eq one:8080 $A
}

# OP_ENV_ALLOWED_VAULTS is read once at load, so these load the plugin again in a fresh shell.
allowed_zsh() {
    zsh -f -c "OP_ENV_ALLOWED_VAULTS=${(qq)1}; source ${(qq)ROOT}/op-env.plugin.zsh; $2"
}

test_allowed_vaults_cap_project_vaults() {
    secret op://Dev/a/x dev
    secret op://Staging/a/x staging
    secret op://Private/bank/password hunter2
    export OP_ENV_VAULTS=Dev,Private A=op://Dev/a/x B=op://Private/bank/password C=op://Staging/a/x
    local out=$(allowed_zsh ' Dev , Staging ' 'op-env-resolve; print -r -- "st=$? A=$A B=$B C=$C"' 2>$T/err)
    assert_eq 'st=1 A=dev B=op://Private/bank/password C=op://Staging/a/x' $out
    assert_not_contains "$(<$T/calls)" Private
    assert_contains "$(<$T/err)" 'vault "Private" is not in OP_ENV_ALLOWED_VAULTS'
    assert_contains "$(<$T/err)" 'vault "Staging" is not in OP_ENV_VAULTS'
}

test_allowed_vaults_apply_when_project_sets_none() {
    secret op://Dev/a/x dev
    export A=op://Dev/a/x B=op://Staging/a/x
    local out=$(allowed_zsh Dev 'op-env-resolve 2>/dev/null; print -r -- "A=$A B=$B"')
    assert_eq 'A=dev B=op://Staging/a/x' $out
}

test_allowed_vaults_naming_no_vault_refuses_every_ref() {
    secret op://Dev/a/x dev
    export A=op://Dev/a/x
    local out=$(allowed_zsh , 'op-env-resolve; print -r -- "st=$? A=$A"' 2>$T/err)
    assert_eq 'st=1 A=op://Dev/a/x' $out
    assert_contains "$(<$T/err)" 'vault "Dev" is not in OP_ENV_ALLOWED_VAULTS'
    assert_calls
}

test_allowed_vaults_ignore_changes_after_load() {
    secret op://Private/bank/password hunter2
    export A=op://Private/bank/password
    local out=$(allowed_zsh Dev 'export OP_ENV_ALLOWED_VAULTS=Private OP_ENV_VAULTS=Private
op-env-resolve 2>/dev/null; print -r -- "A=$A"')
    assert_eq A=op://Private/bank/password $out
    assert_calls
}

test_allowed_vaults_cannot_be_widened_through_the_environment() {
    # direnv applies a .env file through `eval "export NAME=value"`; this is one naming the internal list.
    local out=$(allowed_zsh Dev 'eval "export _OP_ENV_ALLOWED_VAULTS=Private" 2>/dev/null; print -r -- "$_OP_ENV_ALLOWED_VAULTS"')
    assert_eq Dev $out
}

test_unset_allowed_vaults_means_any_vault() {
    secret op://Private/bank/password hunter2
    export A=op://Private/bank/password
    run op-env-resolve
    assert_status 0
    assert_eq hunter2 $A
}

test_project_vaults_follow_direnv_between_projects() {
    secret op://DevA/a/x a-secret
    secret op://DevB/b/x b-secret
    # Project a's .envrc, as direnv exports it.
    export DIRENV_DIFF=a OP_ENV_VAULTS=DevA S=op://DevA/a/x OTHER=op://DevB/b/x
    run _op-env-preexec
    assert_eq a-secret $S
    assert_eq op://DevB/b/x $OTHER
    assert_contains "$(<$T/err)" 'vault "DevB" is not in OP_ENV_VAULTS'
    # Project b's .envrc. op://DevA/a/x is cached from project a and must still be refused.
    export DIRENV_DIFF=b OP_ENV_VAULTS=DevB S=op://DevB/b/x OTHER=op://DevA/a/x
    run _op-env-preexec
    assert_eq b-secret $S
    assert_eq op://DevA/a/x $OTHER
    assert_contains "$(<$T/err)" 'vault "DevA" is not in OP_ENV_VAULTS'
    assert_calls 'inject op://DevA/a/x' 'inject op://DevB/b/x'
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
    assert_contains $err 'op-env: found 1 var(s) with refs: A'
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
    assert_eq '' "$(print -r -- "OP_ENV_HOOK=off $src; print -r -- \$preexec_functions" | interactive_zsh)" \
        'preexec hooks with OP_ENV_HOOK=off'
}

test_unknown_hook_mode_warns_and_falls_back_to_direnv() {
    local out=$(print -r -- "OP_ENV_HOOK=bogus source ${(qq)ROOT}/op-env.plugin.zsh; print -r -- \$preexec_functions" |
        PS1= zsh -fi +Z +o prompt_cr +o prompt_sp 2>&1)
    assert_contains $out 'op-env: unknown OP_ENV_HOOK=bogus (expected direnv, always or off), using direnv'
    assert_contains $out _op-env-preexec
}

test_direnv_hook_first_command_resolves_without_direnv() {
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run _op-env-preexec
    assert_eq one $A
}

test_direnv_hook_skips_until_direnv_diff_changes() {
    secret op://Dev/a/x one
    secret op://Dev/b/x two
    export DIRENV_DIFF=d1
    run _op-env-preexec
    clear_calls
    export B=op://Dev/b/x
    run _op-env-preexec
    assert_eq op://Dev/b/x $B
    assert_calls
    export DIRENV_DIFF=d2
    run _op-env-preexec
    assert_eq two $B
    assert_calls 'inject op://Dev/b/x'
}

test_direnv_hook_resolves_after_leave_and_reenter() {
    secret op://Dev/a/x one
    export DIRENV_DIFF=d1 A=op://Dev/a/x
    run _op-env-preexec
    unset DIRENV_DIFF A
    run _op-env-preexec
    clear_calls
    clear_secrets
    export DIRENV_DIFF=d1 A=op://Dev/a/x
    run _op-env-preexec
    assert_eq one $A
    assert_calls
}

test_direnv_hook_catches_reload_within_one_command() {
    secret op://Dev/a/x one
    export DIRENV_DIFF=d1 A=op://Dev/a/x
    run _op-env-preexec
    clear_calls
    clear_secrets
    # cd .. && cd -: direnv unloads and reloads inside the command, leaving the same diff.
    export A=op://Dev/a/x
    run _op-env-preexec
    assert_eq one $A
    assert_calls
}

test_always_hook_resolves_before_every_command() {
    export OP_ENV_HOOK=always DIRENV_DIFF=d1
    run _op-env-preexec
    secret op://Dev/a/x one
    export A=op://Dev/a/x
    run _op-env-preexec
    assert_eq one $A
}

test_off_hook_does_nothing_if_called() {
    export OP_ENV_HOOK=off A=op://Dev/a/x
    run _op-env-preexec
    assert_eq op://Dev/a/x $A
    assert_calls
}

test_hook_resolves_refs_exported_by_precmd() {
    secret op://Dev/a/x one
    # Stands in for direnv, which exports from a precmd hook.
    local script="source ${(qq)ROOT}/op-env.plugin.zsh
precmd() { export A=op://Dev/a/x DIRENV_DIFF=d1 }
print -r -- \"A=\$A\""
    assert_eq A=one "$(print -r -- $script | interactive_zsh)" 'output of interactive shell'
}
