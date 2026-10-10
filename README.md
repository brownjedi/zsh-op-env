# zsh-op-env

Resolves exported `op://` secret references in place, so `direnv` can keep
plaintext references in `.envrc` and your shell ends up with real values.

```bash
# .envrc
export DATABASE_URL=op://Dev/postgres/connection-string
export STRIPE_KEY=op://Dev/stripe/test-key
```

`cd` into the directory and both variables hold the actual secrets. No
`op run --` wrapper, no committed secrets.

## Requirements

- zsh 5.3+
- [1Password CLI](https://developer.1password.com/docs/cli) (`op`), signed in
- [direnv](https://direnv.net), optional. Without it the plugin still resolves
  references exported from `.zshenv` or a profile. To also resolve ones you
  export by hand later, set `OP_ENV_HOOK=always` or run `op-env-resolve`.

## Install

Load order relative to direnv's hook does not matter.

<details open>
<summary>Manual</summary>

```zsh
# ~/.zshrc
eval "$(direnv hook zsh)"
source /path/to/zsh-op-env/op-env.plugin.zsh
```

</details>

<details>
<summary>antidote</summary>

```zsh
# ~/.zsh_plugins.txt
brownjedi/zsh-op-env
```

</details>

<details>
<summary>zinit</summary>

```zsh
zinit light brownjedi/zsh-op-env
```

</details>

<details>
<summary>sheldon</summary>

```toml
# plugins.toml
[plugins.zsh-op-env]
github = "brownjedi/zsh-op-env"
```

</details>

<details>
<summary>oh-my-zsh</summary>

```zsh
git clone https://github.com/brownjedi/zsh-op-env \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/op-env"
# then, in ~/.zshrc:
plugins=(... direnv op-env)
```

</details>

## Commands

|                          |                                                                                                                      |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `op-env-resolve`         | Force a pass now, bypassing the change guard. Run it after `op signin`. Exits 1 if any reference is left unresolved. |
| `op-env-resolve --debug` | Same, with a trace of which path each secret took. Prints no secret values.                                          |
| `op-env-flush`           | Drop this shell's cache of resolved values.                                                                          |

## Configuration

| Variable                    | Effect                                                                                                                                                                                                                             |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OP_ENV_ALLOWED_VAULTS=Dev` | The most any project may use. Read once, when the plugin loads, so set it _before_ loading. `OP_ENV_VAULTS` can only narrow it. Unset means any vault.                                                                             |
| `OP_ENV_DEBUG=1`            | Trace every pass, including the hook-driven ones.                                                                                                                                                                                  |
| `OP_ENV_HOOK=direnv`        | Default. Resolve before the first command, then only when direnv loads, reloads or unloads an `.envrc` (`$DIRENV_DIFF` changes).                                                                                                   |
| `OP_ENV_HOOK=always`        | Scan before every command, so references exported any other way (by hand, by another plugin) are resolved too.                                                                                                                     |
| `OP_ENV_HOOK=off`           | Don't install the preexec hook; call `op-env-resolve` yourself. Set it _before_ loading.                                                                                                                                           |
| `OP_ENV_NO_CACHE=1`         | Ask `op` every pass instead of caching values in memory.                                                                                                                                                                           |
| `OP_ENV_VAULTS=Dev`         | Only resolve references into these vaults. Others are refused with a warning and never sent to `op`. Read on every pass, so a project can set it in its `.envrc`. Unset means every vault `OP_ENV_ALLOWED_VAULTS` allows.          |

Both vault lists are comma-separated and matched exactly against the vault
part of the reference (name or ID, case-sensitive). Spaces around entries are
ignored.

### Per-project vaults

Set the ceiling once, then let each project narrow it:

```zsh
# ~/.zshrc
OP_ENV_ALLOWED_VAULTS=Work,Personal-Dev
source /path/to/zsh-op-env/op-env.plugin.zsh
```

```bash
# ~/work/api/.envrc
export OP_ENV_VAULTS=Work
export DATABASE_URL=op://Work/postgres/connection-string
```

```bash
# ~/side-project/.envrc
export OP_ENV_VAULTS=Personal-Dev
export OPENAI_API_KEY=op://Personal-Dev/openai/key
```

In `~/work/api`, a reference into `Personal-Dev` is refused, and the other way
round in `~/side-project`, even if the value is already cached from the other
project. A reference into any vault outside `Work,Personal-Dev` is refused
everywhere, whatever an `.envrc` or `.env` file sets `OP_ENV_VAULTS` to. When
you leave a project, direnv unloads its `OP_ENV_VAULTS` along with its secrets.

Without `OP_ENV_ALLOWED_VAULTS`, nothing is restricted unless a project sets
`OP_ENV_VAULTS`, and a project's own files can always set it to any vault.

## How it works

Before a command runs (a `preexec` hook), the plugin scans `$parameters` for
exported scalars whose value is a bare `op://` reference. Running at `preexec`
rather than `precmd` means direnv's hook has always run first, so the command
you just typed sees the resolved values.

By default the scan runs before the first command and then only when
`$DIRENV_DIFF` changes, which direnv does whenever it loads, reloads or unloads
an `.envrc`. Resolving a variable in place does not change `$DIRENV_DIFF`, so
on a normal command the hook does a single string comparison. One extra check
covers `cd .. && cd -` in a single command line, where direnv unloads and
reloads and ends with the same diff: if a variable the plugin resolved holds
its `op://` reference again, the scan runs anyway. With `OP_ENV_HOOK=always`
the scan runs before every command; once a reference is resolved its variable
no longer holds `op://`, so the scan finds nothing and no `op` call is made.

Everything the scan finds is resolved in a single `op inject` call. References
already resolved in this shell come from an in-memory cache, so moving between
directories doesn't re-hit `op`.

Anything the batch doesn't produce is retried one reference at a time with
`op read`. That way a single bad reference can't take down the rest of the
batch, and the error message can name the one that actually broke. If
`op read` fails for any other reason (signed out, authorization prompt
dismissed), the remaining references are skipped instead of prompting once
each.

### Failure behaviour

A reference that can't be resolved keeps its `op://` value rather than becoming
an empty string. Visibly unresolved beats silently empty: it is the
difference between an obvious error and a confusing one deep in an application.
Failed references are not retried before every command, only when the hook
next scans and the set of unresolved references has changed (for example on
`cd`), or when you run `op-env-resolve`. Each is reported once, and again only if it resolves
and later breaks.

### Values are handled verbatim

Secrets are framed with a random delimiter line rather than `NAME=value`, so
values containing `=`, newlines, or trailing blank lines round-trip
byte-for-byte. Multiline secrets such as PEM keys and JSON service-account blobs
come back intact.

## Security notes

- The cache is a zsh associative array: this shell's memory only. It is never
  written to disk and not shared between terminals.
- Only `op`'s stderr is ever written to a temporary file. Secret values stay in
  shell memory.
- `no_xtrace` is set internally, so secrets don't leak into the trace if you
  run with `set -x`.
- **Resolved secrets live in the process environment.** Every child process
  inherits them, and anything running as your user can read
  `/proc/<pid>/environ`. That is inherent to the `direnv` + `op://` approach,
  not something this plugin adds, but it is the real exposure, and it is
  larger than the cache.
- **Any exported `op://` value is resolved, whoever set it.** That includes
  values that come from data files rather than code you wrote, for example a
  `.env` loaded by `dotenv` in an allowed `.envrc`, or by an auto-sourcing
  plugin. Someone who can change that file (a malicious commit, a compromised
  dependency) can point an innocent-looking variable at any secret you can
  read, e.g. `SENTRY_DSN=op://Private/bank/password`, and your app will send
  the resolved value wherever that variable normally goes. direnv's `allow`
  check does not help, because the `.envrc` itself did not change. Set
  `OP_ENV_ALLOWED_VAULTS` in `~/.zshrc` to the vaults your projects actually
  use to limit what such a reference can reach. `OP_ENV_VAULTS` alone does not
  protect you here: the same `.env` file can set it too.
- References containing `{`, `}`, `$` or a control character are refused and
  never sent to `op`, which would read them as template syntax: otherwise
  `op://Dev/a/x }}{{ op://Private/bank/password` would pass the vault checks
  and still resolve the `Private` secret.

## Development

```zsh
zsh tests/run.zsh           # all tests
zsh tests/run.zsh vault     # tests whose name contains "vault"
```

The tests use a fake `op` (`tests/bin/op`), so they need no 1Password account
and never touch real secrets.

## Disclaimer

This plugin was built with AI assistance (Claude, by Anthropic). It handles
secrets, so read the code before you trust it with yours.

## License

MIT
