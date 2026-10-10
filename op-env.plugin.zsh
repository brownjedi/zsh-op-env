# op-env - resolve exported op:// secret references in place.

(( ${+_OP_ENV_LOADED} )) && return 0
typeset -g _OP_ENV_LOADED=1

# zsh plugin standard: find our own directory whether sourced directly, by a plugin manager, or via symlink.
0="${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}"
0="${${(M)0:#/*}:-$PWD/$0}"
typeset -g OP_ENV_HOME="${0:A:h}"

fpath+=("$OP_ENV_HOME/functions")
autoload -Uz op-env-resolve op-env-flush _op-env-resolve _op-env-preexec _op-env-dbg

# ref -> resolved value, for this shell only. Never written to disk.
typeset -gA _OP_ENV_CACHE
# ref -> already reported, so a broken ref is named once, not before every command.
typeset -gA _OP_ENV_WARNED
# Refs the last pass failed on, so they are not retried before every command.
typeset -g  _OP_ENV_LAST_SIG=''
typeset -g OP_ENV_DEBUG="${OP_ENV_DEBUG:-}"

if [[ -o interactive ]] && [[ -z ${OP_ENV_DISABLE_HOOK:-} ]]; then
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _op-env-preexec
fi
