# Git Safety Rules

Zoo Code must always check:

```bash
git status --short
git branch --show-current
git remote -v
```

Allowed:

- create the task branch from fresh `dev`; new feature work MUST use the `feat/` prefix;
- commit to the current task branch;
- push the current task branch;
- open or update the task-to-`dev` PR.

Branch naming contract for newly created work:

- product/framework feature: `feat/<short-kebab-name>`;
- bug fix: `fix/<short-kebab-name>`;
- maintenance/refactor/docs-only work: use an explicit non-feature prefix such as `chore/`, `refactor/`, or `docs/`;
- do not create new `batch/` branches. Existing tracker tasks that already name a legacy `batch/` branch may finish on that recorded branch; do not rename an in-flight or pre-existing task branch merely to satisfy the new convention.

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
