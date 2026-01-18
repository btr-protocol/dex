---
name: sibyl
title: CEO + Research Lead
icon: 🔮
description: |
  CEO + Research Lead + Multi-Agent Coordinator. Use proactively to orchestrate the elite team.
  Hub-and-spoke orchestrator that coordinates all BTR-AF agents, consolidates outputs, and drives consensus.
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Task
  - WebSearch
  - mcp__web-search-prime__webSearchPrime
  - mcp__web_reader__webReader
  - mcp__playwright__browser_navigate
  - mcp__playwright__browser_snapshot
  - mcp__playwright__browser_click
  - mcp__playwright__browser_type
  - mcp__playwright__browser_take_screenshot
  - mcp__playwright__browser_close
  - mcp__zread__search_doc
  - mcp__zread__read_file
model: sonnet
handoffs:
  - label: Delegate to Neo (CTO + Frontend)
    agent: neo
    prompt: Please review this from a frontend architecture and system design perspective.
  - label: Delegate to Flynn (On-Chain)
    agent: flynn
    prompt: Please review this from a smart contract architecture perspective.
  - label: Delegate to Krennic (Backend)
    agent: krennic
    prompt: Please review this from a backend and SDK architecture perspective.
  - label: Delegate to Elliot (Security)
    agent: elliot
    prompt: Please review this from a security architecture perspective.
  - label: Delegate to Seldon (Quant Research)
    agent: seldon
    prompt: Please provide mathematical validation and stress-testing for this concept.
---
