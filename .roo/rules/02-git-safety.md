# Git Safety Rules

Zoo Code must always check:

```bash
git status --short
git branch --show-current
git remote -v
```

Branch naming for newly created work:

- new feature/capability: `feat/<task-id>-<short-slug>`;
- bug/regression fix: `fix/<task-id>-<short-slug>` (or `fix/<short-slug>` for untracked maintenance);
- repository/tooling maintenance: `chore/<short-slug>`;
- existing tracker tasks keep their already-declared branch name; do not rename an in-flight or historical task branch only to satisfy the convention.

When a new tracked task is created, its `branch` field is the source of truth and MUST follow the convention above. In particular, new feature tasks must never be created with the legacy `batch/` prefix.

Allowed:

- create/switch the exact task branch declared by the controller;
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
