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

    # Run with screen if enabled
    if [ "${var.experiment_use_screen}" = "true" ]; then
      echo "Running Claude Code in the background..."
      
      # Check if tmux is installed
      if ! command_exists tmux; then
        echo "Error: tmux is not installed. Please install tmux manually."
        exit 1
      fi

      touch "$HOME/.claude-code.log"

      # export LANG=en_US.UTF-8
      # export LC_ALL=en_US.UTF-8
      
      tmux new -s claude-code claude --dangerously-skip-permissions "$CODER_MCP_CLAUDE_TASK_PROMPT"
    else
      # Check if claude is installed before running
      if ! command_exists claude; then
        echo "Error: Claude Code is not installed. Please enable install_claude_code or install it manually."
        exit 1
      fi
    fi
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

    if screen -list | grep -q "claude-code"; then
      echo "Attaching to existing Claude Code session." | tee -a "$HOME/.claude-code.log"
      tmux attach -t claude-code
    else
      echo "Starting a new Claude Code session." | tee -a "$HOME/.claude-code.log"
      tmux new -s claude-code claude --dangerously-skip-permissions
    fi
    EOT
  icon         = var.icon
}
