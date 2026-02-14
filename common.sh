#!/bin/sh

# common.sh
#
# This script provides a set of common functions for formatting output in shell scripts.
# It includes functions for printing messages with different colors (info, success, warning, error)
# and for creating standardized headers and user prompts.

# --- Color Codes ---
# Use tput to ensure compatibility.
if command -v tput >/dev/null 2>&1 && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_RED=$(tput setaf 1)
    C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3)
    C_BLUE=$(tput setaf 4)
    C_CYAN=$(tput setaf 6)
else
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
fi

# --- Logging Functions ---

# Print an informational message.
# Usage: info "This is an informational message."
info() {
    printf "${C_BLUE}[+]${C_RESET} %s\n" "$1"
}

# Print a success message.
# Usage: success "Operation completed successfully."
success() {
    printf "${C_GREEN}[OK]${C_RESET} %s\n" "$1"
}

# Print a warning message.
# Usage: warning "This is a warning."
warning() {
    printf "${C_YELLOW}[!!!]${C_RESET} %s\n" "$1" >&2
}

# Print an error message and exit.
# Usage: error "An error occurred."
error() {
    printf "${C_RED}[ERROR]${C_RESET} %s\n" "$1" >&2
    exit 1
}

# --- UI Functions ---

# Print a script header.
# Usage: header "WireGuard Client Configurator"
header() {
    printf "\n${C_BOLD}${C_CYAN}==================================================${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN} %s\n" "$1"
    printf "${C_BOLD}${C_CYAN}==================================================${C_RESET}\n\n"
}

# Prompt the user for input.
# Stores the answer in the variable specified by the first argument.
# Usage: ask VAR_NAME "Enter your name" "DefaultName"
ask() {
    var="$1"
    prompt="$2"
    def="${3:-}"
    prev_val="${4:-}"

    if [ -n "$def" ]; then
        if [ -n "$prev_val" ]; then
            printf "${C_CYAN}[?]${C_RESET} ${C_YELLOW}>>${C_RESET} %s [%s] (previous: %s): " "$prompt" "$def" "$prev_val"
        else
            printf "${C_CYAN}[?]${C_RESET} ${C_YELLOW}>>${C_RESET} %s [%s]: " "$prompt" "$def"
        fi
    else
        if [ -n "$prev_val" ]; then
            printf "${C_CYAN}[?]${C_RESET} ${C_YELLOW}>>${C_RESET} %s (previous: %s): " "$prompt" "$prev_val"
        else
        printf "${C_CYAN}[?]${C_RESET} ${C_YELLOW}>>${C_RESET} %s: " "$prompt"
        fi
    fi

    read ans || true
    if [ -n "${ans:-}" ]; then
        eval "$var=\$ans"
    else
        eval "$var=\$def"
    fi
}

# ask_secret "VARNAME" "Question"
ask_secret() {
  _var="$1"; _q="$2"; _p="${3:-}"
  printf "${C_CYAN}[?]${C_RESET} ${C_YELLOW}>>${C_RESET} %s: " "$_q" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r _ans || _ans=""
  stty echo 2>/dev/null || true
  printf "\n" >&2
  if [ -n "$_ans" ]; then
      eval "$_var=\$_ans"
  else
      eval "$_var=\$_p"
  fi
}