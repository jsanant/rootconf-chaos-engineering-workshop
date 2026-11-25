# Offline / poor-network cache

Populate while you have a good network, then use `OFFLINE=1` on constrained links or MITM-heavy networks.

```bash
make cache                 # images → artifacts/images/*.tar + helm charts → artifacts/charts/*.tgz
make all OFFLINE=1         # kind/helm installs from cache; loadgen still builds locally with Go
```

| Path | Contents |
|------|----------|
| `images.txt` | Image list consumed by `make cache-images` |
| `images/*.tar` | `docker save` archives (gitignored) |
| `charts/*.tgz` | `helm pull` chart archives (gitignored) |

Platform note: image tars are architecture-specific when the image is multi-arch *and* you pulled only your host arch. Run `make cache` on each laptop arch you care about (amd64 vs arm64), or use a registry mirror.

The loadgen image `cnpg-loadgen:local` is produced by `make loadgen-build` and also saved into `images/` for reuse.
