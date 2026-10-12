# Heimdall Landing Page — Design Specification & UI Blueprint

> **Reference Inspiration**: [px0.ai](https://px0.ai/)  
> **Target Audience**: Software engineers, technical leads, devops architects, and builders running autonomous AI coding agent workflows.  
> **Brand Identity**: High-performance, terminal-native, multi-device cockpit, zero bloat, cryptographic rigor, friction-free remote access.

---

## 1. Visual Language & Design Tokens

### 1.1 Aesthetic Philosophy
The Heimdall landing page uses an understated, modern developer-platform aesthetic (inspired by Linear, Tailscale, and Oxide):
- **Typography Pairing**: Clean, crisp sans-serif (`Inter`) for all headings, body text, and UI navigation; monospaced (`JetBrains Mono`) strictly for code blocks, CLI commands, and terminal outputs.
- **Understated Dark Theme**: Deep charcoal/slate background (`#0a0c10`) with layered slate surfaces (`#151922`), crisp borders (`#1e2430` / `#293242`), and clean contrast without blinding neon glows.
- **Clean Atmospheric Texture**: Subtle 40px grid overlay without noisy scanlines, arcade scan effects, or garish glowing blobs.
- **Restrained Accents**: Calm sky blue (`#38bdf8`) for interactive focus and highlights, paired with muted emerald (`#10b981`) for live connections and amber (`#f59e0b`) for tasks in validation.

### 1.2 Color Palette & CSS Tokens

```css
:root {
  /* Surfaces */
  --bg-base: #0a0c10;           /* Clean dark slate background */
  --bg-subtle: #11141a;         /* Card background & containers */
  --bg-surface: #151922;        /* Raised interactive surfaces */
  --bg-surface-hover: #1a202c;  /* Hover states */
  --bg-code: #0d1017;           /* Terminal & code block background */
  
  /* Borders */
  --border-subtle: #1e2430;     /* Card dividers, section borders */
  --border-default: #293242;    /* Interactive borders, inputs */
  --border-focus: #3b82f6;      /* Active selection */
  
  /* Text & Foreground */
  --text-main: #f1f5f9;         /* High-contrast headings and primary labels */
  --text-muted: #94a3b8;        /* Body copy, descriptions */
  --text-faint: #64748b;        /* Micro-copy, metadata */
  
  /* Accent & Status */
  --accent: #38bdf8;            /* Restrained sky blue */
  --accent-bg: rgba(56, 189, 248, 0.08);
  --accent-border: rgba(56, 189, 248, 0.25);
  
  --status-green: #10b981;      /* Verified, connected, online */
  --status-green-bg: rgba(16, 185, 129, 0.1);
  --status-amber: #f59e0b;      /* In validation, attention */
  --status-amber-bg: rgba(245, 158, 11, 0.1);
  
  /* Fonts */
  --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  --font-mono: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
}
```

---

## 2. Page Architecture & Section Hierarchy

The landing page follows a single-page narrative optimized for instant technical comprehension and developer conversion:

1. **Top Navigation Bar** (Sticky with live scroll progress indicator, brand pill, and section shortcuts)
2. **Hero Section** (Multi-device headline, plain-English value prop, one-line curl installer, CTAs, BYOA harness pills)
3. **Hero Walkthrough Media Frame** (Dedicated responsive window placeholder for `hero-demo.gif` recording)
4. **Grounded Architectural Capabilities** (6 concrete engineering guarantees: Native Odin, ~20MB RAM, outbound-only tunnels, AES-GCM vault, review gates, BYOA harness)
5. **The 5 Core Feature Pillars** (Deep-dive breakdown with problems, solutions, architecture diagrams, and workflows)
6. **Quick Start & CLI Cheatsheet** (`curl`, `ham-bridge enroll --ui` browser approval, per-bridge unseal in the UI, service management)
7. **Developer FAQ** (Remote access without SSH/VPN, BYOA multi-device fleet, invite model, self-hosting)
8. **Clean Terminal Footer** (System status, Discord, GitHub, Docs, MIT License)

---

## 3. Detailed Component Specifications

### 3.1 Sticky Navigation Bar (`<nav class="nav">`)
- **Left**: Heimdall logo icon (geometric sentinel eye) + `heimdall` bold logotype + version pill (`v0.3.0`).
- **Center**:
  - `Overview` (anchored to `#demo`)
  - `Architecture` (anchored to `#capabilities`)
  - `Pillars` (anchored to `#pillars`)
  - `Quick Start` (anchored to `#cheatsheet`)
  - `FAQ` (anchored to `#faq`)
- **Right**:
  - **Discord Button**: Community link with Discord SVG icon.
  - **GitHub Button**: Repository link.
- **Top**: 2px animated scroll progress bar (`.nav-progress`) indicating reading position across the document.

### 3.2 Hero Section (`<section class="hero">`)
- **Access Status Pill**:
  ```html
  <div class="pill access-pill">
    <span class="dot live pulse"></span>
    <span class="pill-text">Heimdall Cloud is invite-only · Self-host now with 1 command →</span>
  </div>
  ```
- **Announcement Pill**:
  ```html
  <a class="pill announcement-pill" href="/changelog">
    <span class="dot pulse"></span>
    <span class="announcement-text">v0.3.0 released: native binary installer, vault CLI & multi-device fleet</span>
    <span class="arrow">→</span>
  </a>
  ```
- **Metadata Bar**:
  `heimdall v0.3.0 · multi-device agent orchestration · zero-knowledge vault · zero-config remote access`
- **Kicker**: `// coordinate your entire autonomous agent fleet from anywhere.`
- **Headline**:
  ```html
  <h1>
    Your multi-device AI agent fleet.<br>
    <span class="hl">Coordinated. Encrypted. Accessible anywhere.</span>
    <i class="cursor">█</i>
  </h1>
  ```
- **Subheadline**:
  > *"Bring your own agents running across your laptops, workstations, homelabs, and cloud VMs. Heimdall seamlessly orchestrates autonomous teams to work together alongside your built-in editor, VCS, and interactive shell—with zero-knowledge client-side encryption and zero-config remote access without SSH or VPNs."*
- **One-Line Curl Installer Bar**:
  High-visibility terminal input with copy button:
  ```bash
  $ curl -fsSL https://get.heimdall.dev/install.sh | bash
  ```
  *(Clicking copies to clipboard, displays "Copied to clipboard!" with checkmark).*
- **Hero Call-to-Actions (CTAs)**:
  - Primary Action (Self-Host): Instant one-click curl installer bar above.
  - Secondary Action: `[ Join Discord ]` (emerald/cyan neon button with Discord icon for community support).
  - Tertiary Action: `[ Request Cloud Invite ]` (ghost outline button linking to invite waitlist modal).
  - Quaternary Links: `View on GitHub ★` & `See performance benchmarks ↓`.
- **Supported Harnesses (BYOA) Pill Bar**:
  Row of micro-pills with status indicators representing bring-your-own-agent flexibility:
  `[● Antigravity]` `[● Claude Code]` `[● Gemini CLI]` `[● Cursor Agent]` `[● OpenCode]` `[● Aider]` `[● OpenAI Codex]` `[● Goose]` `[● Custom Shell / Script]`

### 3.3 Architectural Guarantees & Capabilities Grid (`<div class="caps-grid">`)
A grounded 6-card architectural capability grid highlighting concrete engineering attributes rather than speculative marketing numbers:

| Pillar | Capability | Technical Detail |
| :--- | :---: | :--- |
| **Runtime** | **Native Odin Binary** | Single static C-ABI binary; zero external Docker, Node, or Python runtime dependencies |
| **Footprint** | **~20MB Resident RAM** | Lightweight native daemon operating under standard systemd (Linux) or launchd (macOS) |
| **Networking** | **Outbound-Only Tunnels** | Outbound TLS WebSockets traverse NAT and firewalls with zero open inbound ports |
| **Security** | **Client-Side AES-GCM** | 256-bit Zero-Knowledge encryption; keys remain strictly local in POSIX 0600 files |
| **Quality** | **Enforced Review Gates** | Multi-agent task lifecycle requires explicit reviewer LGTM verification before code merges |
| **Control** | **Work Alongside Fleet** | Integrated file editor, native Git diff inspector, and live streaming PTY shell takeover |

### 3.4 Hero Media Window & GIF Placeholder (`<section class="hero-media-section" id="demo">`)
A dedicated, responsive media window designed to showcase a live product walkthrough GIF without simulated UI widgets or distracting animations:
- **Chrome Header**:
  - 3 window dots (red `#ef4444`, yellow `#f59e0b`, green `#10b981`).
  - Active session title: `heimdall — multi-device coordination & review quorum demo`.
  - Status pill: `● Live Fleet Session` (indicating active connection).
- **Media Frame & GIF Placeholder**:
  - 16:9 aspect ratio container (`.gif-placeholder`) styled with a clean slate background (`#0e1117`), subtle dashed border, and centered play icon.
  - Title: `[ hero-demo.gif placeholder ]`.
  - Explanatory description: *"Product walk-through recording placeholder: showing coordinator task chain planning, worker parallel execution in isolated PTYs across multiple devices, and reviewer LGTM quorum verification."*
  - Asset metadata badges: `Asset: ./assets/hero-demo.gif` · `Target: 1200 × 680 px` · `Loop: 6–8s`.
  - Future drop-in ready: when the user records `hero-demo.gif` and drops it into `landing-page/assets/`, it replaces the placeholder directly.

---

## 4. The 5 Core Feature Pillars

### Pillar 1: Bring Your Own Agents Across Multiple Devices (BYOA Fleet)
- **The Problem**: Developers use multiple physical machines (laptop, Linux workstation, homelab server, cloud GPU VM) and varied agent frameworks (Claude Code, Cursor, Antigravity, OpenCode, Aider, custom scripts). Running them means juggling disconnected terminal windows, losing context, and manual state synchronization.
- **The Heimdall Solution**:
  - Connect any device with a single-command installer (`curl -fsSL https://get.heimdall.dev/install.sh | bash`).
  - Seamlessly run your choice of agent harness on any connected bridge.
  - View and orchestrate your entire multi-device agent fleet from one unified, reactive cockpit.

### Pillar 2: Seamless Multi-Agent Coordination & Quorum Verification
- **The Problem**: AI coding agents operating in silos hallucinate requirements, make unverified assumptions, overwrite working code, and lack peer review.
- **The Heimdall Solution**:
  - Coordinator agents maintain the living specification, decomposing high-level objectives into structured, self-contained task DAGs.
  - Specialized worker agents execute tasks in parallel with isolated dependencies.
  - Independent reviewer agents run verification suites and cast mandatory `LGTM` quorums with concrete evidence before changes land in your repo.

### Pillar 3: Security-First Architecture (Client-Side Zero-Knowledge Encryption)
- **The Problem**: Centralized multi-agent platforms upload workspace credentials, environment variables, source code, and API keys to central cloud databases in plaintext.
- **The Heimdall Solution**:
  - Client-side Zero-Knowledge encryption: all data leaving your machine is wrapped in 256-bit AES-GCM envelopes (`vault:v1:...`).
  - The central Hub is zero-knowledge: it coordinates tasks and logs without ever seeing your repository code, prompts, or API keys in plaintext.
  - Encryption keys stay strictly on your own devices: the browser holds the master-password-wrapped key, and each bridge keeps its own key in the OS keyring/Keychain after you unseal it.

### Pillar 4: Zero-Config Remote Access (No SSH, No VPN, No Port Forwarding)
- **The Problem**: Accessing your development workstation or homelab agent fleet on the go requires brittle SSH tunnels, dynamic DNS, Tailscale/VPN configs, or punching holes in router firewalls.
- **The Heimdall Solution**:
  - Engineered from day one for seamless remote development.
  - Heimdall bridges establish secure, persistent outbound WebSocket tunnels to the Hub.
  - Pick up your work, inspect agent progress, and trigger tasks from anywhere in the world without opening a single inbound port or configuring a VPN.

### Pillar 5: Work Alongside Your Fleet (Editor, VCS & Interactive Shell)
- **The Problem**: AI agent tools often operate as opaque black boxes behind chat prompts, leaving developers disconnected from repository changes until disaster strikes.
- **The Heimdall Solution**:
  - Full human-in-the-loop pair programming: you work alongside your agent fleet in real time.
  - Integrated file editor and native Git VCS diff viewer allow you to inspect, edit, and guide changes as they happen.
  - Low-latency interactive PTY terminal streaming (`ham-pty-host`) lets you jump into any agent's live shell session with zero latency.

---

## 5. CLI Quick Start & Cheatsheet

```bash
# 1. Install via frictionless one-liner
curl -fsSL https://get.heimdall.dev/install.sh | bash

# 2. Enroll your local node — approve it in a browser, no token to copy
ham-bridge enroll --ui https://heimdall.yourdomain.com
#    Prints an approval link; open it on any device and approve. A short code is
#    printed as a fallback when the link cannot be opened. Add --headless if this
#    machine has no browser. --ui is the UI ORIGIN (scheme + host, no path).

# 3. Inspect daemon status and multi-device connections
heimdall status

# 4. Manage local bridge service lifecycle
heimdall start
heimdall logs -f
heimdall doctor
heimdall update --check
```

---

## 6. Developer FAQ (`<section class="faq">`)

1. **What is Heimdall?**  
   Heimdall is an enterprise-grade multi-agent manager and orchestrator built with Odin. It coordinates teams of autonomous AI coding agents operating across multiple host environments with transaction-safe tasks, strict review gates, and zero-knowledge encryption.

2. **How does remote access work without SSH or VPN?**  
   Heimdall bridges initiate outbound TLS WebSocket connections to your Hub. Because connections are outbound, you can access your workstation or homelab agent fleet from anywhere without configuring firewall port-forwarding, dynamic DNS, or VPN clients like Tailscale.

3. **How does Heimdall protect my code and secrets?**  
   Heimdall uses a Zero-Knowledge Vault architecture. Your Master Password derives a 256-bit AES-GCM wrapping key entirely in your client browser/UI. All data that leaves your local device is encrypted ciphertext (`vault:v1:...`). The Hub never sees plaintext prompts, code, or API keys.

4. **Can I bring my own existing coding agents?**  
   Yes. Heimdall is completely harness-agnostic (BYOA). It seamlessly manages Antigravity, Claude Code, Gemini CLI, Cursor Agent, OpenCode, Aider, and custom agent runtimes through its universal PTY bridge (`ham-pty-host`).

5. **Can I work alongside my agents while they code?**  
   Yes. Heimdall includes a built-in code editor, native Git VCS diff viewer, and interactive PTY terminal streaming. You can review intermediate diffs, make manual edits, or jump into an agent's shell at any time.

6. **Does Heimdall require Docker or Kubernetes?**  
   No. Heimdall compiles to static native binaries with zero external runtime dependencies and runs as a lightweight user systemd unit (Linux) or launchd service (macOS) using ~20MB of RAM.

---

## 7. Deliverable Status & Architecture

### 7.1 Architecture & Hosting Pattern
- **Delivery**: Standalone zero-dependency HTML/CSS document (`landing-page/index.html`) optimized for instant rendering and previewability via Heimdall bridge proxy.
- **Styling**: Single self-contained CSS token stylesheet using `Inter` for prose and `JetBrains Mono` for code/CLI, maintaining an understated, high-contrast engineering aesthetic without neon flares.
- **Media Window**: Dedicated responsive 16:9 placeholder frame for `hero-demo.gif` with clear dimensions (1200×680px) and loop guidelines.
- **Live Preview**: Served locally via Python HTTP server on port 8085 and proxied via Heimdall Hub preview endpoint.

### 7.2 Deliverable Checklist
- [x] Author comprehensive design blueprint: `landing-page/DESIGN.md`
- [x] Implement self-contained standalone page: `landing-page/index.html`
- [x] Remove simulated console stage and marketing comparison table per feedback
- [x] Integrate dedicated Hero Media frame with `hero-demo.gif` recording placeholder
- [x] Add grounded Architectural Guarantees grid (~20MB RAM, Native Odin, Outbound WS)
- [x] Build 5 Core Feature Pillars deep-dive and FAQ accordion
- [x] Serve live via Heimdall bridge proxy session (`sh_18d8e30d70e08a0f`)
