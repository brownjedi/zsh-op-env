# op-env - resolve exported op:// secret references in place.

(( ${+_OP_ENV_LOADED} )) && return 0
typeset -g _OP_ENV_LOADED=1

# zsh plugin standard: find our own directory whether sourced directly, by a plugin manager, or via symlink.
0="${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -g OP_ENV_HOME="${0:A:h}"

fpath+=("$OP_ENV_HOME/functions")
autoload -Uz op-env-resolve op-env-flush _op-env-resolve _op-env-preexec _op-env-dbg _op-env-split-vaults

# ref -> resolved value, for this shell only. Never written to disk.
typeset -gA _OP_ENV_CACHE
# ref -> already reported, so a broken ref is named once, not before every command.
typeset -gA _OP_ENV_WARNED
# Refs the last pass failed on, so they are not retried before every command.
typeset -g  _OP_ENV_LAST_SIG=''
# Names holding a resolved secret, so the hook can spot one direnv set back to its op:// ref.
typeset -gaU _OP_ENV_RESOLVED
# _OP_ENV_LAST_DIFF: $DIRENV_DIFF the hook last ran for. Left unset so the first command always gets a pass.
typeset -g OP_ENV_DEBUG="${OP_ENV_DEBUG:-}"

# Read once and readonly, so neither direnv nor a .env file it loads can widen it later. Empty means any vault.
typeset -ga _OP_ENV_ALLOWED_VAULTS
_op-env-split-vaults _OP_ENV_ALLOWED_VAULTS "${OP_ENV_ALLOWED_VAULTS:-}"
typeset -gr _OP_ENV_ALLOWED_VAULTS

if [[ -o interactive && ${OP_ENV_HOOK:-direnv} != off ]]; then
    [[ ${OP_ENV_HOOK:-direnv} == (direnv|always) ]] ||
        print -ru2 -- "op-env: unknown OP_ENV_HOOK=$OP_ENV_HOOK (expected direnv, always or off), using direnv"
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _op-env-preexec
fi
