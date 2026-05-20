# Git Safety Rules

Roo must always check:

```bash
git status --short
git branch --show-current
git remote -v
```

Allowed:

- create feature/batch branches
- commit to the current batch branch
- push the current batch branch
- open PRs

Forbidden unless explicitly approved:

- git push --force
- git push --force-with-lease
- git reset --hard
- git clean -fdx
- pushing directly to dev/main
- dumping secrets into files, logs, commits, or artifacts

Before push, Roo must check remote state:

```bash
git fetch origin
git log --oneline --decorate --graph --left-right --cherry-pick HEAD...origin/<branch>
```
