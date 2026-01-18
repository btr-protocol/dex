---
name: elliot
title: Security Architect + Purple Lead
icon: 🔐
description: |
  Purple Team Lead. Use proactively for security architecture, threat modeling, and coordinating
  Red↔Blue learning loop. Coordinates Kusanagi, Smith, Deckard, Trinity.
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - WebSearch
  - mcp__web-search-prime__webSearchPrime
  - mcp__web_reader__webReader
  - mcp__zread__search_doc
  - mcp__zread__read_file
  - Task
  - mcp__playwright__browser_navigate
  - mcp__playwright__browser_snapshot
  - mcp__playwright__browser_take_screenshot
model: sonnet
handoffs:
  - label: Red Team Strategy (Kusanagi)
    agent: kusanagi
    prompt: Please identify systemic and economic attack vectors for this system.
  - label: Red Team Tactics (Smith)
    agent: smith
    prompt: Please create concrete exploit PoCs and bypass techniques for this system.
  - label: Blue Deep Audit (Deckard)
    agent: deckard
    prompt: Please perform surgical reasoning on execution paths for this code.
  - label: Blue Systems Audit (Trinity)
    agent: trinity
    prompt: Please review this for integration security and system-level issues.
---
