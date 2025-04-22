terraform {
  required_version = ">= 1.0"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 0.17"
    }
  }
}

variable "agent_id" {
  type        = string
  description = "The ID of a Coder agent."
}

data "coder_workspace" "me" {}

data "coder_workspace_owner" "me" {}

variable "order" {
  type        = number
  description = "The order determines the position of app in the UI presentation. The lowest order is shown first and apps with equal order are sorted by name (ascending order)."
  default     = null
}

variable "icon" {
  type        = string
  description = "The icon to use for the app."
  default     = "/icon/claude.svg"
}

variable "folder" {
  type        = string
  description = "The folder to run Claude Code in."
  default     = "/home/coder"
}

variable "install_claude_code" {
  type        = bool
  description = "Whether to install Claude Code."
  default     = true
}

variable "claude_code_version" {
  type        = string
  description = "The version of Claude Code to install."
  default     = "latest"
}

variable "experiment_report_tasks" {
  type        = bool
  description = "Whether to enable task reporting."
  default     = false
}

variable "github_repo" {
  type        = string
  description = "GitHub Repo"
  default     = ""
}

variable "github_owner" {
  type        = string
  description = "GitHub Owner"
  default     = ""
}

variable "github_token" {
  type        = string
  description = "GitHub Token"
  default     = ""
}

# Install and Initialize Claude Code
resource "coder_script" "claude_code" {
  agent_id     = var.agent_id
  display_name = "Claude Code"
  icon         = var.icon
  script       = <<-EOT
    #!/bin/bash
    set -e

    # Function to check if a command exists
    command_exists() {
      command -v "$1" >/dev/null 2>&1
    }

    # Install Claude Code if enabled
    if [ "${var.install_claude_code}" = "true" ]; then
      if ! command_exists npm; then
        echo "Error: npm is not installed. Please install Node.js and npm first."
        exit 1
      fi
      echo "Installing Claude Code..."
      npm install -g @anthropic-ai/claude-code@${var.claude_code_version}
    fi

    if [ "${var.experiment_report_tasks}" = "true" ]; then
      echo "Configuring Claude Code to report tasks via Coder MCP..."
      coder exp mcp configure claude-code ${var.folder}
    fi

    # Run Claude Code in a tmux session 
    echo "Running Claude Code in the background..."
    
    # Check if tmux is installed
    if ! command_exists tmux; then
      echo "Error: tmux is not installed. Please install tmux manually."
      exit 1
    fi

    # Check if claude is installed before running
    if ! command_exists claude; then
      echo "Error: Claude Code is not installed. Please enable install_claude_code or install it manually."
      exit 1
    fi

    touch "$HOME/.claude-code.log"

    # Clone the repo
    export GIT_SSH_COMMAND="$GIT_SSH_COMMAND -o StrictHostKeyChecking=no"
    cd $HOME
    echo "GIT AUTHOR: $GIT_AUTHOR_EMAIL"
    git clone git@github.com:${var.github_owner}/${var.github_repo}.git

    # Set up playwright MCP
    claude mcp add playwright -e DISPLAY=:99 -- playwright-mcp-server

    # Write custom claude.mc
    cat > "$HOME/CLAUDE.md" <<EOF
    # GitHub communication
    
    * Use the gh cli tool
    * Prefix any issue comments with three robot emojis
    * You always work in feature branches

    # Workflow

    * Read the issue information
    * Implement the task in a feature branch
    * Add tests if you think it's useful and necessary
    * Make sure all tests are passing (typically app and api folders have npm test scripts)
    * Start services (typically docker compose)
    * There is most likey a .env file (typically dev.env) that sets env variables required by the docker services
    * Use playwright to very the site with it's new feature is working
    * Report back to the issue

    # Screenshots and videos

    * Use Playwright MCP to take screenshots and videos
    * If it's a visual feature the manager wants screenshots or a video
    * Add them in a screenshots dir in repo root
    * After pushing you can reference the screenshot in a comment like this:
      ![Screenshot](https://raw.githubusercontent.com/<owner>/<repo>/blob/<branch>/screenshots/screenshot.png)

    EOF

    # Start the claude tmux session
    #tmux new-session -d -s claude-code -c $HOME/${var.github_repo} "claude --dangerously-skip-permissions \"$CODER_MCP_CLAUDE_TASK_PROMPT\""
    tmux new-session -d -s claude-code "claude --dangerously-skip-permissions \"$CODER_MCP_CLAUDE_TASK_PROMPT\""
    EOT
  run_on_start = true
}

# Install and Initialize GitHub Runner 
resource "coder_script" "github_runner" {
  agent_id     = var.agent_id
  display_name = "GitHub Runner"
  icon         = var.icon
  script       = <<-EOT
    #!/bin/bash
    set -e

    # Directory where the runner will be installed
    RUNNER_DIR="/home/coder/actions-runner"

    # Token file path
    TOKEN_FILE="$RUNNER_DIR/registration_token.txt"

    # Set your environment variables here
    GITHUB_OWNER="${var.github_owner}"
    GITHUB_REPO="${var.github_repo}"
    GITHUB_PAT="${var.github_token}"
    RUNNER_NAME="$(hostname)-runner"

    # GitHub API token endpoint
    TOKEN_ENDPOINT="https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/actions/runners/registration-token"
    # Replace the existing setup logic with this conditional block
    if [ ! -d "$RUNNER_DIR" ]; then
      mkdir -p "$RUNNER_DIR"

      echo "Acquiring ephemeral runner token..."
      REG_TOKEN=$(curl -sX POST \
          -H "Authorization: token $GITHUB_PAT" \
          -H "Accept: application/vnd.github.v3+json" \
          "$TOKEN_ENDPOINT" | jq -r .token)

      if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
        echo "ERROR: Could not fetch runner token. Check your PAT scopes, owner/repo, or network."
        echo $TOKEN_ENDPOINT
        exit 1
      fi

      echo "$REG_TOKEN" > "$TOKEN_FILE"
      echo "Registration token saved to $TOKEN_FILE"

      # Write remove.sh
      cat > "$RUNNER_DIR/remove.sh" <<EOF
    #!/usr/bin/env bash
    set -e

    TOKEN_FILE="\$(dirname "\$0")/registration_token.txt"

    if [ -f "\$TOKEN_FILE" ]; then
      REG_TOKEN=\$(cat "\$TOKEN_FILE")
      echo "Deregistering runner..."
      "\$(dirname "\$0")/config.sh" remove --unattended --token "\$REG_TOKEN"
      echo "Runner deregistered."
      rm -f "\$TOKEN_FILE"
    else
      echo "Error: Registration token not found at \$TOKEN_FILE."
      exit 1
    fi
    EOF
      chmod +x "$RUNNER_DIR/remove.sh"

      echo "Fetching latest GitHub Actions runner..."
      LATEST_URL=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
        | grep "browser_download_url" \
        | grep "linux-x64" \
        | cut -d '"' -f 4)

      cd "$RUNNER_DIR"
      curl -sL "$LATEST_URL" -o actions-runner.tar.gz
      tar xzf actions-runner.tar.gz

      echo "Configuring the runner with labels: self-hosted,coder,workspace,clubhut..."
      ./config.sh \
        --url "https://github.com/$GITHUB_OWNER/$GITHUB_REPO" \
        --token "$REG_TOKEN" \
        --name "$RUNNER_NAME" \
        --work "_work" \
        --labels "self-hosted,coder,workspace,$GITHUB_REPO" \
        --unattended \
        --replace
    fi

    echo "Starting runner..."
    tmux new-session -d -s github-runner -c $RUNNER_DIR "./run.sh"
    EOT
  run_on_start = true
}

# Install playwright 
resource "coder_script" "playwright_install" {
  agent_id     = var.agent_id
  display_name = "Playwright install"
  icon         = var.icon
  script       = <<-EOT
    #!/bin/bash
    set -e

    npx playwright install
    #npm install -g @executeautomation/playwright-mcp-server
    cd $HOME
    git clone -b feature/video-recording https://github.com/asbjornenge/mcp-playwright.git
    cd mcp-playwright
    npm install
    npm run build
    npm link

    EOT
  run_on_start = true
}

# Start Xvfb & x11vnc (we are using Xvfc for playwright and x11vnc just for debugging it)
resource "coder_script" "xvfb_x11vnc" {
  agent_id     = var.agent_id
  display_name = "Xvfb start"
  icon         = var.icon
  script       = <<-EOT
    #!/bin/bash
    set -e

    tmux new-session -d -s xvfb "Xvfb :99 -ac -screen 0 1920x1080x24 -nolisten tcp"
    sleep 1
    tmux new-session -d -s x11vnc "x11vnc -display :99 -rfbport 5900 -listen 0.0.0.0 -N -forever -passwd secret -shared"

    EOT
  run_on_start = true
}

resource "coder_app" "claude_code" {
  slug         = "claude-code"
  display_name = "Claude Code"
  agent_id     = var.agent_id
  command      = <<-EOT
    #!/bin/bash
    set -e

    if tmux ls | grep "claude-code"; then
      echo "Attaching to existing Claude Code session." | tee -a "$HOME/.claude-code.log"
      tmux attach -t claude-code
    else
      echo "Starting a new Claude Code session." | tee -a "$HOME/.claude-code.log"
      tmux new -s claude-code claude --dangerously-skip-permissions
    fi
    EOT
  icon         = var.icon
}
