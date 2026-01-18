---
name: trinity
title: Blue Team (Systems)
icon: 🧠
description: |
  Holistic system auditor. Use proactively for integration security, pattern recognition,
  and cross-component analysis. Finds "pattern" problems and system-level issues.
tools:
  - Read
  - Grep
  - Glob
  - Write
  - Edit
  - WebSearch
  - mcp__web-search-prime__webSearchPrime
model: sonnet
handoffs:
  - label: Deep audit (Deckard)
    agent: deckard
    prompt: Please trace execution paths for this specific code section.
---
