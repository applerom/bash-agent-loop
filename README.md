# Bash Agent Loop

Working agent loop in Bash.

Small enough to read in one sitting. Real enough to run in a few minutes.

- about 200 lines
- `curl` + `jq`
- one tool: `run_bash`
- OpenAI function calling

If you want to understand what an agent loop really is, this repo shows the core idea without framework noise.

## Run It

```bash
cp .env.example .env
```

Put your OpenAI key into `.env`, then:

```bash
./agent.sh
```

On Windows, use Git Bash.

`agent.sh` loads `.env` automatically if the file exists.

## What It Does

1. Send your task to the model.
2. Let the model ask for `run_bash`.
3. Run the command locally.
4. Send the result back to the model.
5. Repeat until the model gives a normal answer.

## Try These

```bash
./agent.sh "How many lines are in agent.sh?"
./agent.sh "Count all shell scripts in this repo"
```

## Files

- `agent.sh` - the full agent
- `.env.example` - config example
- `.agent-work/` - saved request/response JSON

## Why This Repo Exists

Most people hear "AI agent" and imagine a large framework.

This repo makes the opposite point:

> the core loop can fit in one small Bash file.
