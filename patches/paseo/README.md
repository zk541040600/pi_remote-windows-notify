# Paseo 0.14 notification compatibility patch

This patch fixes **our `paseo-sender` integration**, not the upstream Paseo
application or daemon. It applies to `pi_remote-windows-notify` before the
subscription fix (base commit `428167a`), with Paseo daemon `0.14.0` and the
sender's pinned `@getpaseo/client` `0.3.0-beta.2`.

## Why

Paseo 0.14 gates `agent_attention_required` broadcasts on an `agents`
subscription for this client type. A one-shot `fetchAgents()` snapshot plus
`selective_agent_timeline` capability is not enough: the sender can be
connected and healthy while missing completion/permission events.

The patch adds a stable `subscribe.subscriptionId` **only on the first page**
of each agent reconciliation, checks the server's subscription acknowledgement,
and re-subscribes when reconciliation runs after reconnect. Subsequent pages
remain ordinary snapshot reads. Tests cover attention delivery, future agents,
reconnect and invalid acknowledgements.

## Apply to an unpatched checkout

From the repository root at the pre-fix base (or a matching revision):

```bash
git apply --check patches/paseo/0.14.0-attention-subscription.patch
git apply patches/paseo/0.14.0-attention-subscription.patch
npm --prefix linux/paseo-sender test
npm --prefix linux/paseo-sender run check
```

This repository already contains the applied fix on current branches, so do
**not** reapply the patch there. The file is preserved for auditing and
forward-porting; routine upstream Paseo upgrades do not overwrite these sender
sources. If Paseo changes its subscription protocol again, verify the contract
against the installed daemon before adapting it.

Deploy by restarting **only** the `paseo-sender` user service after validating;
do not restart the Paseo daemon. This patch does not implement Windows desktop
cold-start or change the separate `app-absent` readiness policy.
