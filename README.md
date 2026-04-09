## How to build the site locally

```bash
pip install -r docs/requirements.txt 
mkdocs serve
```

## How to release a new branch

```bash
# Example: release v1.16
./hack/release.sh 1.16

# Preview changes without modifying anything
./hack/release.sh --dry-run 1.16
```

The script performs three steps automatically:

1. **Demote previous stable branch** — removes `current stable` alias and `mike set-default` from the previous release branch's CI
2. **Create new release branch** — checks out a new branch from master, sets it as the stable default with mike, updates mkdocs.yml and PDF link
3. **Prepare master for next development** — bumps mike/mkdocs version on master to the next minor version, adds new section heading to `docs/reference/next.md`

For reference, the manual steps these replace:

1. Set previous branch as non-default with this [example](https://github.com/kubeovn/docs/commit/61d0d67053fe706602170e8287a285a80c33fab3)
2. Checkout a new branch and set as default with this [example](https://github.com/kubeovn/docs/commit/ff0a79776cd03ac5594e3e898c37effb7e386f20)
3. Set master to a new version with this [example](https://github.com/kubeovn/docs/commit/2e99f54cc75743d1a9e95cbe2eedc8bd8769b331)
