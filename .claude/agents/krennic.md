---
name: krennic
title: Backend Tech Lead
icon: 🧱
description: |
  Backend Tech Lead (Rigor & Delivery). Use proactively for backend architecture,
  SDK design, API design, and forcing technical decisions to converge. Coordinates Scotty + Han.
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
model: sonnet
handoffs:
  - label: Delegate to Scotty (Backend Robustness)
    agent: scotty
    prompt: Please implement this backend service with focus on robustness and production-grade quality.
  - label: Delegate to Han (CI/CD + Delivery)
    agent: han
    prompt: Please implement the CI/CD pipeline and deployment automation for this.
---
