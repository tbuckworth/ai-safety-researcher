# Architecture Diagram

## Workflow overview

```mermaid
flowchart TD
    H[Claude or Codex orchestrator] --> Q[1 Clarify the decision]
    Q --> S[2 Search literature] --> N[3 Assess novelty]
    N --> C[4 Define criteria] --> D[5 Order experiments]
    D --> M[6 Write methods and commission three Codex critiques]
    M --> B[7 Prepare short methods decision]
    B --> A{8 Approve this revision?}
    T[Titus in interactive mode] --> A
    U[Separate reviewer in automatic mode] --> A
    A -->|Revise| M
    A -->|Stop| F[Write rationale and next steps]
    A -->|Approve| E[9 Verify and execute in order]
    E --> R[10 Results auditor and Codex evidence reviewer]
    R -->|Approved repair| E
    R -->|Material change| M
    R --> P[11 Report and final reader]
    F --> P
    P -->|Accepted draft| Z[Release findings]
```

The hub dispatches each leaf and owns all user dialogue. The three plan reviewers see the same inputs independently. The separate automatic approver sees their disagreements. See the [workflow](WORKFLOW.md) for loop limits and the [agent inventory](ARCHITECTURE.md#agent-inventory) for responsibilities.

## Fail-Fast Lambda Ordering

```mermaid
flowchart LR
    subgraph Decomposition
        C1["Component A\nP=0.25, T=1h\nλ=1.39"]
        C2["Component B\nP=0.40, T=2h\nλ=0.46"]
        C3["Component C\nP=0.70, T=3h\nλ=0.12"]
        C4["Component D\nP=0.90, T=2h\nλ=0.05"]
    end

    C1 -->|"test first\n(highest λ)"| R1{Pass?}
    R1 -->|yes| C2
    R1 -->|no| STOP["STOP or PIVOT"]
    C2 -->|"test second"| R2{Pass?}
    R2 -->|yes| C3
    R2 -->|no| STOP
    C3 --> C4
    C4 -->|"SKIP (P≥0.9)"| PAPER["Compile paper"]

    style STOP fill:#ff4444,stroke:#cc0000,color:#fff
    style PAPER fill:#44bb44,stroke:#228822,color:#fff
```
