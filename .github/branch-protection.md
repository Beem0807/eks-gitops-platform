# Branch Protection - `main`

Documents the branch protection rules configured on `main`. These settings enforce that all CI checks pass before any PR can be merged.

## Rules

| Rule | Setting |
|------|---------|
| Require pull request before merging | ✅ Enabled - Required approvals: **0** |
| Require status checks to pass | ✅ Enabled - see checks below |
| Require branches to be up to date | ✅ Enabled |
| Require conversation resolution | ✅ Enabled |
| Require linear history | ✅ Enabled |
| Restrict direct pushes to `main` | ✅ Enabled |
| Require review from Code Owners | ❌ Disabled |

## Required status checks

| Check | Workflow |
|-------|----------|
| `App Image CI` | `.github/workflows/app-image.yaml` |
| `Terraform CI` | `.github/workflows/terraform-ci.yaml` |
| `GitOps CI` | `.github/workflows/gitops-ci.yaml` |
| `CODEOWNERS Check` | `.github/workflows/codeowners-check.yaml` |
| `GitHub Actions Check` | `.github/workflows/actions-check.yaml` |
| `PR Title Check` | `.github/workflows/pr-title-check.yaml` |

Each check only triggers when its relevant paths change. A check that was not triggered by a PR is treated as passing - only triggered checks must succeed.

## Notes

**Required approvals: 0** - PRs can self-merge once all required status checks pass. Suitable for a solo project; increase to 1 when collaborators are added.

**CODEOWNERS disabled** - `.github/CODEOWNERS` is present but "Require review from Code Owners" is off. The file is ready to enforce reviews if a second owner is added to the project.

See [CI.md](CI.md) for full documentation on what each workflow validates.
