- load all your guidelines and tools from the folder .agents or .agents folders in subdirectories
- never change this file. If you are asked to change rules etc do it in the .agents folder
- never add content to CLAUDE.md file.
- Store rules in .agents/rules or .agents/context

This project uses `.agents/` for persistent memory.

- Auto-managed (agent saves on its own initiative): `.agents/auto-memory/`
- User-requested (parked decisions, investigations, ongoing context): `.agents/requested-memory/`

NEVER write persistent content to `.claude/` or `~/.claude/`. Save new memories under the appropriate `.agents/` subdir; update existing ones in place.

@.agents/auto-memory/MEMORY.md
@.agents/requested-memory/MEMORY.md
