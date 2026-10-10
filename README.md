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

| Variable                    | Effect                                                                                                                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OP_ENV_ALLOWED_VAULTS=Dev` | The most any project may use. Read once, when the plugin loads, so set it _before_ loading. `OP_ENV_VAULTS` can only narrow it. Unset means any vault.                                                                    |
| `OP_ENV_DEBUG=1`            | Trace every pass, including the hook-driven ones.                                                                                                                                                                         |
| `OP_ENV_HOOK=direnv`        | Default. Resolve before the first command, then only when direnv loads, reloads or unloads an `.envrc` (`$DIRENV_DIFF` changes).                                                                                          |
| `OP_ENV_HOOK=always`        | Scan before every command, so references exported any other way (by hand, by another plugin) are resolved too.                                                                                                            |
| `OP_ENV_HOOK=off`           | Don't install the preexec hook; call `op-env-resolve` yourself. Set it _before_ loading.                                                                                                                                  |
| `OP_ENV_NO_CACHE=1`         | Ask `op` every pass instead of caching values in memory.                                                                                                                                                                  |
| `OP_ENV_VAULTS=Dev`         | Only resolve references into these vaults. Others are refused with a warning and never sent to `op`. Read on every pass, so a project can set it in its `.envrc`. Unset means every vault `OP_ENV_ALLOWED_VAULTS` allows. |

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

### `.env` files

To keep a `.env` file, put references in it instead of values and have
direnv load it with `dotenv` or `dotenv_if_exists`:

```bash
# .env
DB_PASSWORD=op://Dev/db/password
DATABASE_URL="postgres://{{ op://Dev/db/user }}:{{ op://Dev/db/password }}@db/app"
```

```bash
# .envrc
dotenv_if_exists
```

After `direnv allow`, direnv exports the variables and the plugin resolves
them like any other. The file holds no values, so it is safe to commit.

The file itself still contains references. A program that reads `.env` on
its own sees the resolved values only if its loader keeps variables already in
the environment, which is the default for Node's `dotenv`, `python-dotenv`
and Vite. Loaders that override, or that pass the file straight through (for
example Docker Compose `env_file:`), get the `op://` text.

Changes to `.env` do not need a new `direnv allow`, so set
`OP_ENV_ALLOWED_VAULTS` (see [Security notes](#security-notes)).

## How it works

Before a command runs (a `preexec` hook), the plugin scans `$parameters` for
exported scalars whose value is a bare `op://` reference or contains
`{{ op://... }}` tags. Running at `preexec` rather than `precmd` means direnv's
hook has always run first, so the command you just typed sees the resolved
values.

By default the scan runs before the first command and then only when
`$DIRENV_DIFF` changes, which direnv does whenever it loads, reloads or unloads
an `.envrc`. Resolving a variable in place does not change `$DIRENV_DIFF`, so
on a normal command the hook does a single string comparison. One extra check
covers `cd .. && cd -` in a single command line, where direnv unloads and
reloads and ends with the same diff: if a variable the plugin resolved holds
its reference again, the scan runs anyway. With `OP_ENV_HOOK=always` the scan
runs before every command; it skips values the plugin set itself, so once
everything is resolved no `op` call is made.

Everything the scan finds is resolved in a single `op inject` call. References
already resolved in this shell come from an in-memory cache, so moving between
directories doesn't re-hit `op`.

Anything the batch doesn't produce is retried one reference at a time with
`op read`. That way a single bad reference can't take down the rest of the
batch, and the error message can name the one that actually broke. If
`op read` fails for any other reason (signed out, authorization prompt
dismissed), the remaining references are skipped instead of prompting once
each.

### References inside a value

To combine a secret with other text, wrap the reference in `{{ }}`, the tag
syntax `op inject` uses:

```bash
# .envrc
export API_ADDR='{{ op://Dev/api/host }}:8443'
export DATABASE_URL='postgres://{{ op://Dev/db/user }}:{{ op://Dev/db/password }}@db/app'
```

`export B="$A:8080"` does not work: the shell expands `$A` while it still holds
the reference, so `B` becomes `op://...:8080`, which names a different field.
Write `export B="{{ $A }}:8080"` instead.

- Each tag's reference gets the same vault checks, batch and cache as a
  whole-value reference.
- Text outside tags is kept as is, including a bare `op://` and `$VAR`. Your
  value is never handed to `op inject` as a template, so `op`'s own variable
  expansion does not apply.
- All or nothing: if any tag fails, the variable keeps its original value.
- Tags don't nest. As with `op inject`, `{{ op://Dev/{{ op://Dev/a/x }}/f }}`
  is refused; compose with shell variables instead.
- Substituted secrets are not scanned again, so a secret whose value contains
  `{{ op://... }}` stays verbatim.

### Commands on the same line as `cd`

The hook runs once, before the whole command line. In `cd proj && make`,
direnv loads `proj/.envrc` during the `cd`, after the hook has already run, so
`make` sees the raw `op://` references. The next command line sees the
resolved values. To use them on the same line, resolve explicitly after the
`cd`:

```zsh
cd proj && op-env-resolve && make
```

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
- A value the plugin set is never treated as a reference again, even if the
  secret itself contains `op://` text or `{{ }}` tags, so a secret cannot make
  the plugin read another secret.

## Compared with 1Password Environments

[1Password Environments](https://www.1password.dev/environments/overview.md)
solve a similar problem in a different way. An Environment is a set of
key-value variables stored in 1Password, separate from vault items. You
create one in the desktop app (or import an existing `.env`), then deliver
it through a
[locally mounted `.env` file](https://www.1password.dev/environments/local-env-file.md),
[`op run --environment <id> -- <command>` or `op environment read <id>`](https://www.1password.dev/environments/read-environment-variables.md),
the Go, JavaScript and Python SDKs, an
[MCP server](https://www.1password.dev/environments/mcp-server.md), or a sync
to AWS Secrets Manager.

This plugin keeps secrets as ordinary vault items and points at them with
`op://` references from `.envrc`. The two are not mutually exclusive.

This comparison reflects the 1Password docs as of October 2026. Environments
were still changing then (the CLI commands were in beta), so check the linked
pages for the current state.

### At a glance

|                           | zsh-op-env                                                                                         | 1Password Environments                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Where secrets live        | Ordinary vault items, any field                                                                    | Environments, a separate store of key-value variables                                                                                      |
| What the project commits  | `.envrc`, or a `.env` it loads, with `op://` references: readable, reviewable, no values           | Nothing. The mounted `.env` path must stay untracked, and `op run` needs the Environment ID                                                |
| How values arrive         | Exported into your interactive shell, inherited by every command you run                           | Read on demand from a FIFO `.env` file, or injected into one subprocess by `op run`, or fetched by an SDK                                  |
| One secret, many projects | One vault item referenced from any number of `.envrc` files; rotate it once                        | Variables belong to an Environment. The docs describe no way to reference a vault item, so a shared secret is copied into each Environment |
| Composing values          | `{{ op://... }}` tags inside a value, e.g. a `postgres://` URL built from user and password fields | Each variable is a literal value                                                                                                           |
| Access control            | Vault permissions, plus `OP_ENV_ALLOWED_VAULTS` / `OP_ENV_VAULTS` on top                           | Per-Environment view, edit and manage permissions, granted separately for each Environment                                                 |
| Prompts and caching       | One `op inject` batch per change, then an in-memory cache for the life of the shell                | Desktop app authorizes a read, and the approval lasts until 1Password locks                                                                |
| Output masking            | None                                                                                               | Variables are hidden by default and masked in CLI and SDK output                                                                           |
| Shell and OS              | zsh 5.3+ only, wherever zsh and `op` run                                                           | Any shell. Desktop app on macOS, Windows and Linux; mounted `.env` files on macOS and Linux only                                           |
| Prerequisites             | `op`, signed in any way it supports. direnv optional                                               | 1Password subscription, desktop app, and an Owner or Administrator must turn on the Environments policy                                    |
| Limits                    | None of its own                                                                                    | Up to ten enabled mounted `.env` files per device                                                                                          |
| CI and automation         | Not its job: the hook only runs in interactive shells. Use `op run` or `op inject` there           | Service accounts with scoped access, SDKs, AWS Secrets Manager sync                                                                        |
| AI coding agents          | An agent started from a resolved shell inherits the plaintext values                               | MCP server and agent plugins that, by design, never return secret values to the agent                                                      |
| Cost and maturity         | MIT, about 300 lines of zsh, built with AI assistance                                              | First-party and supported by 1Password; CLI commands in beta                                                                               |

### Pros of zsh-op-env

- **Uses the vault items you already have.** No migration and no second copy
  of a secret. A key used by five projects is one item, so rotation is one
  edit.
- **The project documents itself.** Which secret feeds which variable is
  visible in `.envrc` or `.env`, in the repository and in code review, without
  exposing a value. An Environment's contents are only visible in 1Password.
- **Keeps your `.env` file.** Replace values with references and load the file
  with direnv's `dotenv` (see [`.env` files](#env-files)). The file is a
  regular file, so none of the FIFO problems below apply.
- **Works with every tool unchanged.** Values are plain environment
  variables, so `make`, `docker compose`, test runners, debuggers and editors
  launched from the shell see them without a wrapper or a `.env` loader.
- **No FIFO side effects.** Mounted `.env` files have documented problems:
  only the first of several concurrent readers is guaranteed to succeed, file
  watchers such as Vite can restart in a loop because each read emits
  filesystem events, and a previously tracked `.env` must be removed from Git
  first. None of that applies to variables in the environment.
- **Composes values.** `{{ op://... }}` tags build connection strings and URLs
  from several fields; Environments store each variable as a literal.
- **Few calls to `op`.** One batched `op inject` per change, then an
  in-memory cache, so moving between directories does not re-prompt.
- **No account policy needed.** It works with any account `op` can sign in
  to, including ones where an administrator has not enabled Environments, and
  has no per-device file limit.
- **Small and auditable.** About 300 lines of zsh with a fake-`op` test suite.

### Cons of zsh-op-env

- **Secrets sit in your shell's environment.** Every child process inherits
  them, anything running as your user can read `/proc/<pid>/environ`, and an
  AI agent or other tool started from that shell gets them too. A mounted
  `.env` or `op run` limits exposure to the process that asked.
- **Any exported reference is resolved.** A malicious commit or a `.env`
  loaded by `dotenv` can point a variable at any secret you can read (see
  [Security notes](#security-notes)). `OP_ENV_ALLOWED_VAULTS` limits the blast
  radius but has to be set. An Environment exposes only its own variables, so
  a tampered project file cannot redirect it to another secret.
- **zsh only, interactive only.** No bash, fish or Windows shells, no CI.
  Scripts and pipelines still need `op run` or `op inject`.
- **No masking.** A resolved value printed by a command appears in plain text.
  `op run` masks secrets in output by default.
- **Timing edge cases.** Commands on the same line as `cd` see raw references
  unless you add `op-env-resolve` (see
  [Commands on the same line as `cd`](#commands-on-the-same-line-as-cd)).
- **Access control is per vault.** Sharing one project's secrets means
  sharing a vault, or splitting items into project vaults. Environments grant
  access per project.

### Which to choose

Choose this plugin if your secrets already live in vaults, you work in zsh
with direnv, you want the mapping from variables to secrets reviewable in the
repository, or you want to keep a `.env` file that holds references instead
of values.

Choose Environments if you want first-party support, per-project sharing with
a team, values that never enter your shell's environment, protection from AI
agents reading secrets, or the same variables in CI and AWS through service
accounts and sync.

The two can share a machine. This plugin only acts on exported `op://`
references, so it ignores projects that use a mounted `.env` file or
`op run --environment`.

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
