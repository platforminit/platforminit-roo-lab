# Environment Rules

Roo must run from VS Code Remote WSL.

Required environment:

- WSL: Ubuntu-22.04
- Workspace: /mnt/d/SYSADMIN/platforminit-roo-lab
- User: hattila

Before modifying files, Roo must verify:

```bash
pwd
grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK
id -un
git branch --show-current
git status --short
```

Forbidden environments:

- Windows CMD
- PowerShell
- Git Bash
- MobaXterm shell
- local Windows VS Code extension host

If the environment check fails, Roo must stop.
