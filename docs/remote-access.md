# Remote access

Phantom is shared with a few colleagues over Tailscale, at **https://store-1.taild0096.ts.net:8443**. Tailscale is
the only login: the app has no authentication of its own, so it must never be exposed outside the tailnet.

## How it's set up

Tailscale Serve terminates HTTPS (a Let's Encrypt certificate for the ts.net name) and proxies to the app, which
listens only on localhost:

```bash
tailscale serve --bg --https=8443 http://127.0.0.1:4000   # survives reboots
tailscale serve status
tailscale serve --https=8443 off                          # stop sharing
```

This needs Serve and HTTPS certificates enabled for the tailnet (admin console), and the user as Tailscale operator
(`sudo tailscale set --operator=$USER`, once) so `tailscale serve` works without sudo.

**Why 8443 and not 443:** MicroK8s' ingress-nginx on store-1 takes ports 80 and 443 on every address, the
Tailscale one included, and answers with its "Kubernetes Ingress Controller Fake Certificate". Serve only allows
443, 8443 and 10000, so Phantom uses 8443. Disabling the ingress add-on (`microk8s disable ingress`) would free 443.

The Python services (`:8000`, `:8001`) stay on 127.0.0.1 and are reached only through the app.

## Giving a colleague access

1. In the Tailscale admin console, **Machines → store-1 → Share**, and send them the invite link. They need a free
   Tailscale account and see only store-1, not the rest of the tailnet.
2. Restrict shared users to Phantom in the tailnet policy file. With the default allow-all policy they can also
   reach SSH (22) and the MicroK8s API and kubelet ports (16443, 10250, …) on store-1.

## Known gaps

- The app runs as `mix phx.server` in dev mode, so it's down whenever that terminal session or the machine is.
  Running a prod release under systemd, with Postgres backups, is the next step.
- Anyone with access can start runs on the GPU, and generated images grow without limit on disk.
- Going public (Cloudflare Tunnel with Cloudflare Access, plus login in the app and limits on runs) was considered
  and left out: everyone who needs access can use Tailscale.
