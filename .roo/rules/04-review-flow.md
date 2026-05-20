# Review Flow Rules

Use a batch lifecycle for Roo Code work.

Preferred lifecycle:

1. Project Orchestrator reads `tasks/active/NEXT_TASK.md`.
2. Project DeepSeek Coder completes the implementation tasks on one batch branch.
3. Project OpenAI Reviewer performs a changed-files-only review.
4. Project OWASP Reviewer performs a read-only security, content, privacy, and release review.
5. Project Orchestrator validates, prepares the PR, and updates task status.

Rules:

- Do not run OWASP review after every individual task.
- Do not create a PR after every individual task.
- Do not let the OWASP reviewer make code changes without explicit human approval.
- Keep commits on the current batch branch.
- Keep the human entrypoint to one prompt: `Read tasks/active/NEXT_TASK.md and execute the active batch exactly as described.`
