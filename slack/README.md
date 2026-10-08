# headlong-slack-bridge

A Slack Socket Mode bridge that connects one Headlong identity to a Slack
workspace. Org members DM the bot or @mention it in channels; messages land
in the identity's mind log as `message` steps, and the identity's replies
are posted back to the right conversation.

## How it works

```
Slack <=(Socket Mode websocket)=> headlong-slack-bridge
    inbound:  event -> from_name "slack-<user>-<channel>[-<thread_ts>]"
              -> POST <web>/api/identities/<id>/chat
              first @mention in an existing thread prepends a capped
              prior-line digest (conversations.replies, fail-open)
              reaction_added on the bot's messages (and any DM reaction)
              lands as a `:emoji:` body (same from_name / thread)
    outbound: tail trajectory.jsonl -> message steps where from=<identity>
              and to=slack-* -> chat.postMessage, files.upload_v2 when
              the step has filename (chat send-file), or reactions.add
              when the step has reaction (chat react)
```

The Slack conversation is encoded into the chat `from` name, which the
reply path returns as `to` — so no trajectory schema changes and no agent
changes are needed. Channel replies always go in-thread; DM replies go top
level. The bridge is a pure client of the existing web API and trajectory
format.

## Running

```bash
export SLACK_BOT_TOKEN=xoxb-...     # see "Slack app lifecycle" below
export SLACK_APP_TOKEN=xapp-...
export HEADLONG_SLACK_IDENTITY=ada    # optional; defaults to the `default`
                                      # identity link (legacy SHELLM_SLACK_IDENTITY
                                      # still honored)
tools/headlong-slack-bridge [ROOT]      # ROOT = serve root, default repo root
```

The launcher loads `<checkout>/.env` and then `$HEADLONG_HOME/.env` (default
`~/.headlong/.env`), the same two files `persona` and `llm` read, so the
tokens can live in an env file instead of the calling shell. Anything already
exported wins, which is what keeps systemd's `EnvironmentFile` and `slack run`
in charge where they are used.

The identity must exist (`identity new <name>`) with a running dispatcher
(`thinkers start monolith responder`), and headlong-web must be serving the same root
(default `http://127.0.0.1:8080`, override with `HEADLONG_WEB_URL`; legacy `SHELLM_WEB_URL` still honored).

Socket Mode is outbound-only: no public endpoint, works behind NAT, and
keeps the zero-ingress deploy design. On a deployed box both the bridge and
the web server run as systemd units (`deploy/headlong-slack-bridge.service`,
`deploy/headlong-web.service`); `deploy/terraform-slack/` is the stack Laude
runs its own Slack-connected agent on.

Other settings: `HEADLONG_SLACK_STATE_DIR`, legacy `SHELLM_SLACK_STATE_DIR`
(cursor + thread state, default
`<identity>/run/slack-bridge/`; the deployed unit sets it to
`/var/lib/shellm-slack`, owned by the bridge's own user), `SLACK_THREAD_FOLLOWUPS=1` (answer
un-mentioned replies in threads the bot is already part of),
`SLACK_THREAD_JOIN_BACKFILL` (how many closest prior messages above a first @mention
to prepend; default 20, 0 disables, max 50), and peer hearing:
`SLACK_PEER_BOT_USERS` (comma-separated bot user ids of other Headlong
personas whose posts may reach this mind; empty keeps every bot post
dropped), `SLACK_PEER_MAX_TURNS` (peer messages forwarded in one thread in a
row with no person speaking; default 4) and `SLACK_PEER_HOURLY_CAP` (peer
messages forwarded per hour; default 30). See
[design/peer_hearing.md](../design/peer_hearing.md).

For the end-to-end procedure we used to install our agent, Audel, into a
workspace on that stack (Slack app, tokens, SSM env, rebuild, verification),
see [PLAYBOOK.md](PLAYBOOK.md).

## Slack app lifecycle (Slack CLI)

`manifest.json` in this directory is the app's source of truth; manage the
Slack-side lifecycle with the [Slack CLI](https://docs.slack.dev/tools/slack-cli/)
from this directory:

```bash
cd slack
slack login                      # once per developer
slack app link --environment deployed   # once: attach the workspace app (or
                                        # let the CLI create it from manifest.json)
slack manifest validate          # after editing manifest.json
slack app install --environment deployed  # push manifest + reinstall (new scopes)
slack run                        # local dev: CLI-managed dev app + tokens,
                                 # runs the bridge against the repo root
```

`manifest.harris.json` is the same app definition for the second persona,
Harris, which has its own Slack app and bot user (so the two personas post
as different bots and the bridge on each box only sees its own tokens).
It was created from that file with "Create New App → From a manifest" in
the laudesters workspace; keep the two files in step when scopes change.

Scope changes become: edit `manifest.json` → `slack manifest validate` →
`slack app install`. Production still uses the long-lived `xoxb-`/`xapp-`
tokens from app settings, stored in the box's SSM env parameter — the CLI
does not replace that step (app-level tokens are minted once under Basic
Information → App-Level Tokens, scope `connections:write`). Box-side day-2
(deploys, restarts) stays with `deploy/scripts/*`.

## Tests

```bash
uv run --project slack pytest slack/tests
```

Outbound `chat send-file` posts use Slack `files.upload_v2` and need the bot scope `files:write` in addition to `chat:write`. A scope change requires reinstall / re-grant.

## Security notes

Read this before widening beyond a pilot channel.

- **Workspace membership is the only gate.** Anyone in the workspace can
  message the bot, and the agent can run arbitrary bash on its box with its
  API keys. Mitigations: dedicated burnable instance, zero inbound network
  access, its own spend-capped LLM key, dash behind Cloudflare Access.
- **Prompt injection.** Slack message content (including pasted/forwarded
  text) flows straight into the agent's context. Treat anything the bot is
  told as potentially adversarial input.
- **Exfiltration.** The box allows all egress; a successfully injected
  agent could send secrets out. Keep only the secrets this box needs in its
  env.
- **One shared mind.** All conversations interleave in a single mind log.
  Anything one person tells the identity may surface in replies to others.
  Do not tell it secrets you would not post in a public channel.
