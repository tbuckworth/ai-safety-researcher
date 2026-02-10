---
name: ai-safety-researcher
description: This skill should be used when the user asks to "research", "investigate", "survey the literature on", "analyse AI safety", "run a research process", "systematic review", "study whether", "explore the feasibility of", "write a paper on", "fail-fast analysis of", or any request related to conducting structured AI safety research, literature review, novelty assessment, experiment design, or paper compilation.
version: 0.2.0
---

# AI Safety Research Workflow

When this skill is triggered, invoke the `/researcher` command to run the full end-to-end research process. If the user has provided a specific topic, pass it as the argument.

This plugin provides a 10-step interactive research workflow:
1. Clarify the research topic with the user
2. Conduct structured literature search (academic, lab blogs, community)
3. Assess novelty against existing work
4. Define success criteria and SOTA benchmarks
5. Steinhardt fail-fast decomposition (lambda ordering)
6. Challenge the research plan (assumption analysis, steelman review, pre-mortem)
7. Report planned experiments to user
8. Confirm fail-fast agreement
9. Execute experiments in lambda order
10. Compile LaTeX research paper
