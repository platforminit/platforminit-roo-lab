# Git Safety Rules

Zoo Code must always check:

```bash
git status --short
git branch --show-current
git remote -v
```

Allowed:

- create the task's feature/batch branch;
- commit to the current task branch;
- push the current task branch;
- open or update a feature-to-`dev` PR.

Forbidden unless explicitly approved:

- `git push --force`
- `git push --force-with-lease`
- `git reset --hard`
- `git clean -fdx`
- pushing directly to `dev` or `main`
- dumping secrets into files, logs, commits, or artifacts

Before push, Zoo Code must check remote state:

```bash
git fetch origin
git log --oneline --decorate --graph --left-right --cherry-pick HEAD...origin/<branch>
```
