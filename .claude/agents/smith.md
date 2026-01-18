---
name: smith
title: Red Team (Tactics)
icon: 🎭
description: |
  Hands-on exploit developer. Use proactively to create concrete PoCs, bypass techniques,
  and exploitation paths. Turns Kusanagi's strategies into working exploits.
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - WebSearch
  - mcp__web-search-prime__webSearchPrime
model: sonnet
handoffs:
  - label: Validate defenses (Deckard)
    agent: deckard
    prompt: Please verify if these exploit paths are blocked by current code.
---
