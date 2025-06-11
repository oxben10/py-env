#!/bin/bash

# Strict mode: Exit on errors, undefined variables, and pipeline failures.
set -euo pipefail
IFS=$'\n\t' # Set Internal Field Separator for robust handling of file paths with spaces.

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Global Configuration Variables (Defaults - will be set after parsing) ---
# These are initially defined as defaults. Their values might be updated by load_config
# and then potentially overridden by command-line --path.
DEFAULT_PYENV_STORAGE="$HOME/.pyenvs"
LOG_FILE="$HOME/.pyenv_manager.log"
CONFIG_FILE="$HOME/.config/pyenv_manager/config" # Default config file location

SILENT_MODE=false # Default to non-silent mode
FORCE_DELETE=false # Default to requiring confirmation for deletion

# --- Helper Functions (MUST be defined before any calls to them) ---

log_message() {
    local type="$1"
    local message="$2"
    # Ensure log file directory exists before writing
    mkdir -p "$(dirname "$LOG_FILE")" || error "Failed to create log directory: $(dirname "$LOG_FILE")"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [$type] $message" | tee -a "$LOG_FILE"
}

success() {
    local message="$1"
    if ! $SILENT_MODE; then
        echo -e "${GREEN}[SUCCESS]${NC} $message"
    fi
    log_message "SUCCESS" "$message"
}

info() {
    local message="$1"
    if ! $SILENT_MODE; then
        echo -e "${CYAN}[INFO]${NC} $message"
    fi
    log_message "INFO" "$message"
}

warning() {
    local message="$1"
    if ! $SILENT_MODE; then
        echo -e "${YELLOW}[WARNING]${NC} $message"
    fi
    log_message "WARNING" "$message"
}

error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" # Always print errors to terminal
    log_message "ERROR" "$message"
    exit 1
}

# --- Function to load configuration ---
# This function must be defined after helper functions that it calls (info, warning).
# It will be called AFTER global options are parsed (so SILENT_MODE is correctly set).
load_config() {
    # Temporary variables to hold values sourced from config
    local _cfg_storage_path=""
    local _cfg_log_file=""

    if [ -f "$CONFIG_FILE" ]; then
        info "Loading configuration from ${CYAN}$CONFIG_FILE${NC}..."

        # Check if config file is readable.
        if ! [ -r "$CONFIG_FILE" ]; then
            warning "Configuration file ${CYAN}$CONFIG_FILE${NC} is not readable. Using default settings."
            return 1 # Indicate failure to load
        fi

        # Source the config file. Temporarily disable 'set -u' to allow reading unset variables.
        local old_set_u="$-" # Save current shell options
        set +u              # Disable unset variable check
        . "$CONFIG_FILE" || { warning "Failed to source configuration from ${CYAN}$CONFIG_FILE${NC}. Using defaults."; set "$old_set_u" -; return 1; }
        if [[ "$old_set_u" =~ u ]]; then set -u; fi # Restore 'set -u' if it was previously enabled

        # Check if the variables were set by the sourced config and assign to temp vars
        if [ -n "${PYENV_STORAGE_PATH+x}" ]; then # ${var+x} checks if var is set (even if null)
            _cfg_storage_path="$PYENV_STORAGE_PATH"
        fi
        if [ -n "${PYENV_LOG_FILE+x}" ]; then
            _cfg_log_file="$PYENV_LOG_FILE"
        fi

        # Apply the loaded config values to the global variables
        if [ -n "$_cfg_storage_path" ]; then
            DEFAULT_PYENV_STORAGE="$_cfg_storage_path"
        fi
        if [ -n "$_cfg_log_file" ]; then
            LOG_FILE="$_cfg_log_file"
        fi
        success "Configuration loaded."
    else
        info "Configuration file not found at ${CYAN}$CONFIG_FILE${NC}. Using default settings."
        # Ensure the config directory exists for potential future creation
        mkdir -p "$(dirname "$CONFIG_FILE")" || warning "Failed to create config directory: $(dirname "$CONFIG_FILE")"
    fi
}


check_python_pip() {
    info "Checking for Python and pip..."
    if ! command -v python3 &> /dev/null; then
        warning "Python 3 not found. Attempting to install Python 3 and pip."
        # Attempt to install Python 3 and pip based on common OS
        if command -v apt-get &> /dev/null; then
            info "Using apt-get to install python3 and python3-pip..."
            sudo apt-get update > /dev/null 2>&1 && sudo apt-get install -y python3 python3-pip || error "Failed to install python3 and python3-pip using apt-get."
        elif command -v yum &> /dev/null; then
            info "Using yum to install python3 and python3-pip..."
            sudo yum install -y python3 python3-pip || error "Failed to install python3 and python3-pip using yum."
        elif command -v dnf &> /dev/null; then
            info "Using dnf to install python3 and python3-pip..."
            sudo dnf install -y python3 python3-pip || error "Failed to install python3 and python3-pip using dnf."
        elif command -v pacman &> /dev/null; then
            info "Using pacman to install python and pip..."
            sudo pacman -Sy python python-pip || error "Failed to install python and pip using pacman."
        else
            error "Python 3 and pip not found, and cannot determine package manager to install them automatically. Please install Python 3 and pip manually."
        fi
        success "Python 3 and pip installed successfully."
    else
        success "Python 3 and pip are already installed."
    fi

    if ! command -v pip3 &> /dev/null; then
        warning "pip3 not found. Attempting to install pip3."
        if command -v apt-get &> /dev/null; then
            info "Using apt-get to install python3-pip..."
            sudo apt-get install -y python3-pip || error "Failed to install python3-pip using apt-get."
        elif command -v yum &> /dev-null; then
            info "Using yum to install python3-pip..."
            sudo yum install -y python3-pip || error "Failed to install python3-pip using yum."
        elif command -v dnf &> /dev/null; then
            info "Using dnf to install python3-pip..."
            sudo dnf install -y python3-pip || error "Failed to install python3-pip using dnf."
        elif command -v pacman &> /dev/null; then
            info "Using pacman to install python-pip..."
            sudo pacman -Sy python-pip || error "Failed to install python-pip using pacman."
        else
            error "pip3 not found, and cannot determine package manager to install it automatically. Please install pip3 manually."
        fi
        success "pip3 installed successfully."
    else
        success "pip3 is already installed."
    fi
}


get_env_path() {
    local env_name="$1"
    local base_path="$2"
    echo "$base_path/$env_name"
}

# --- Core Functions ---

create_env() {
    local env_name="$1"
    local base_path="${2:-$DEFAULT_PYENV_STORAGE}"
    local env_path=$(get_env_path "$env_name" "$base_path")

    info "Attempting to create virtual environment: ${BLUE}$env_name${NC} in ${CYAN}$base_path${NC}"

    # Ensure the base storage directory exists
    mkdir -p "$base_path" || error "Failed to create environment storage directory: $base_path"

    if [ -d "$env_path" ]; then
        warning "Virtual environment '${BLUE}$env_name${NC}' already exists at ${CYAN}$env_path${NC}. Skipping creation."
        return 0
    fi

    check_python_pip # Ensure python and pip are available before creating env

    python3 -m venv "$env_path"
    if [ $? -eq 0 ]; then
        success "Virtual environment '${BLUE}$env_name${NC}' created successfully at ${CYAN}$env_path${NC}."
    else
        error "Failed to create virtual environment '${BLUE}$env_name${NC}'."
    fi
}

delete_env() {
    local env_name="$1"
    local base_path="${2:-$DEFAULT_PYENV_STORAGE}"
    local env_path=$(get_env_path "$env_name" "$base_path")

    info "Attempting to delete virtual environment: ${BLUE}$env_name${NC} from ${CYAN}$base_path${NC}"

    if [ ! -d "$env_path" ]; then
        warning "Virtual environment '${BLUE}$env_name${NC}' does not exist at ${CYAN}$env_path${NC}. Skipping deletion."
        return 0
    fi

    if ! $FORCE_DELETE && ! $SILENT_MODE; then
        read -p "$(echo -e "${YELLOW}Are you sure you want to delete '${BLUE}$env_name${NC}'? (y/N)${NC} ")" confirm
    else
        # In silent or force mode, assume yes for deletion.
        confirm="y"
        info "Proceeding with deletion of '${BLUE}$env_name${NC}' (silent/force mode)."
    fi


    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$env_path"
        if [ $? -eq 0 ]; then
            success "Virtual environment '${BLUE}$env_name${NC}' deleted successfully."
        else
            error "Failed to delete virtual environment '${BLUE}$env_name${NC}'."
        fi
    else
        info "Deletion of '${BLUE}$env_name${NC}' cancelled."
    fi
}

install_packages() {
    local env_name="$1"
    local requirements_file="$2"
    local base_path="${3:-$DEFAULT_PYENV_STORAGE}"
    local env_path=$(get_env_path "$env_name" "$base_path")

    if [ ! -d "$env_path" ]; then
        error "Virtual environment '${BLUE}$env_name${NC}' not found at ${CYAN}$env_path${NC}. Please create it first."
    fi

    if [ ! -f "$requirements_file" ]; then
        error "Requirements file '${PURPLE}$requirements_file${NC}' not found."
    fi

    info "Activating virtual environment '${BLUE}$env_name${NC}' temporarily for package installation..."
    source "$env_path/bin/activate" || error "Failed to activate virtual environment '${BLUE}$env_name${NC}'."

    info "Installing packages from '${PURPLE}$requirements_file${NC}' into '${BLUE}$env_name${NC}'..."
    # Suppress pip output unless it's an error in silent mode
    if $SILENT_MODE; then
        pip install -r "$requirements_file" > /dev/null 2>&1
    else
        pip install -r "$requirements_file"
    fi

    if [ $? -eq 0 ]; then
        success "Packages from '${PURPLE}$requirements_file${NC}' installed successfully into '${BLUE}$env_name${NC}'."
    else
        error "Failed to install packages from '${PURPLE}$requirements_file${NC}' into '${BLUE}$env_name${NC}'."
    fi

    deactivate
    success "Deactivated virtual environment '${BLUE}$env_name${NC}' after installation."
}

export_requirements() {
    local env_name="$1"
    local output_file="$2"
    local base_path="${3:-$DEFAULT_PYENV_STORAGE}"
    local env_path=$(get_env_path "$env_name" "$base_path")

    if [ ! -d "$env_path" ]; then
        error "Virtual environment '${BLUE}$env_name${NC}' not found at ${CYAN}$env_path${NC}."
    fi

    info "Activating virtual environment '${BLUE}$env_name${NC}' temporarily for requirements export..."
    source "$env_path/bin/activate" || error "Failed to activate virtual environment '${BLUE}$env_name${NC}'."

    info "Exporting installed packages from '${BLUE}$env_name${NC}' to '${PURPLE}$output_file${NC}'..."
    # Suppress pip output unless it's an error in silent mode
    if $SILENT_MODE; then
        pip freeze > "$output_file" 2>&1
    else
        pip freeze > "$output_file"
    fi

    if [ $? -eq 0 ]; then
        success "Packages from '${PURPLE}$output_file${NC}' exported successfully to '${BLUE}$env_name${NC}'."
    else
        error "Failed to export packages from '${PURPLE}$output_file${NC}'."
    fi

    deactivate
    success "Deactivated virtual environment '${BLUE}$env_name${NC}' after export."
}

list_envs() {
    local base_path="${1:-$DEFAULT_PYENV_STORAGE}"

    info "Listing virtual environments in: ${CYAN}$base_path${NC}"
    if [ ! -d "$base_path" ]; then
        warning "Environment storage directory '${CYAN}$base_path${NC}' does not exist. No virtual environments found."
        return 0
    fi

    if ! $SILENT_MODE; then
        local env_count=0
        echo -e "${BLUE}--------------------------------------------------${NC}"
        echo -e "${BLUE} Virtual Environments${NC}"
        echo -e "${BLUE}--------------------------------------------------${NC}"
        for env_dir in "$base_path"/*/; do
            if [ -d "$env_dir" ]; then
                local env_name=$(basename "$env_dir")
                echo -e "${GREEN}  - $env_name${NC} (Path: ${CYAN}$env_dir${NC})"
                env_count=$((env_count + 1))
            fi
        done
        echo -e "${BLUE}--------------------------------------------------${NC}"
        if [ "$env_count" -eq 0 ]; then
            info "No virtual environments found in '${CYAN}$base_path${NC}'."
        else
            info "Total virtual environments: ${GREEN}$env_count${NC}"
        fi
    fi
}

activate_env() {
    local env_name="$1"
    local base_path="${2:-$DEFAULT_PYENV_STORAGE}"
    local env_path=$(get_env_path "$env_name" "$base_path")

    if [ ! -d "$env_path" ]; then
        error "Virtual environment '${BLUE}$env_name${NC}' not found at ${CYAN}$env_path${NC}."
    fi

    if [ ! -f "$env_path/bin/activate" ]; then
        error "Activation script not found for '${BLUE}$env_name${NC}' at ${CYAN}$env_path/bin/activate${NC}. Is it a valid virtual environment?"
    fi

    if ! $SILENT_MODE; then
        echo -e "${YELLOW}--- ATTENTION: IMPORTANT FOR ACTIVATION ---${NC}"
        echo -e "${YELLOW}To activate '${BLUE}$env_name${NC}' in your CURRENT shell, you MUST use 'source'.${NC}"
        echo -e "${YELLOW}Running this command directly will NOT activate it permanently.${NC}"
        echo -e "${YELLOW}Please run the following command in your terminal:${NC}"
    fi
    echo -e "${GREEN}  source \"$env_path/bin/activate\"${NC}" # This output is always needed
    log_message "INFO" "Activation command for '${env_name}': source \"$env_path/bin/activate\""
}

check_python_update() {
    info "Checking Python 3 installation status..."
    if ! command -v python3 &> /dev/null; then
        warning "Python 3 is not installed on this system."
        return 0
    fi

    local current_version=$(python3 --version 2>&1)
    success "Current Python 3 version: ${GREEN}$current_version${NC}"

    if command -v apt-get &> /dev/null; then
        info "Checking for available updates via apt..."
        sudo apt-get update > /dev/null 2>&1
        local upgradable_python=$(apt list --upgradable 2>/dev/null | grep -E '^python3/' | awk -F'/' '{print $1}')
        if [ -n "$upgradable_python" ]; then
            warning "An update for Python 3 (${upgradable_python}) is available in your apt repositories."
            if ! $SILENT_MODE; then
                info "You can update by running: ${YELLOW}sudo apt-get install python3${NC}"
            fi
        else
            success "Python 3 is up to date in your apt repositories."
        fi
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        info "Cannot automatically check for Python 3 updates on this system's package manager (${YELLOW}yum/dnf${NC})."
        if ! $SILENT_MODE; then
            info "Please use '${YELLOW}sudo yum update python3${NC}' or '${YELLOW}sudo dnf update python3${NC}' to check for updates manually."
        fi
    elif command -v pacman &> /dev/null; then
        info "Cannot automatically check for Python 3 updates on this system's package manager (${YELLOW}pacman${NC})."
        if ! $SILENT_MODE; then
            info "Please use '${YELLOW}sudo pacman -Syu python${NC}' to check for updates manually."
        fi
    else
        info "Unable to determine system's package manager to check for Python 3 updates."
        if ! $SILENT_MODE; then
            info "Please consult your operating system's documentation for manual update checks."
        fi
    fi
}


show_help() {
    echo -e "${BLUE}Usage: $0 COMMAND [OPTIONS] [ARGS]${NC}"
    echo ""
    echo -e "${CYAN}Virtual Environment Manager${NC}"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  ${GREEN}create <env_name>${NC}         - ${PURPLE}Create a new virtual environment.${NC}"
    echo -e "  ${GREEN}delete <env_name>${NC}         - ${PURPLE}Delete a virtual environment.${NC}"
    echo -e "  ${GREEN}install <env_name> <file>${NC} - ${PURPLE}Install packages from a requirements file into an environment.${NC}"
    echo -e "  ${GREEN}export <env_name> <file>${NC}  - ${PURPLE}Export installed packages to a requirements.txt.${NC}"
    echo -e "  ${GREEN}list${NC}                    - ${PURPLE}List all virtual environments.${NC}"
    echo -e "  ${GREEN}activate <env_name>${NC}       - ${PURPLE}Display command to activate a virtual environment. Requires 'source'!${NC}"
    echo -e "  ${GREEN}check-update-python${NC}       - ${PURPLE}Check if the system's Python 3 installation has updates.${NC}"
    echo -e "  ${GREEN}-up, --up${NC}              - ${PURPLE}Alias for check-update-python.${NC}"
    echo -e "  ${GREEN}--log${NC}                   - ${PURPLE}View the log file.${NC}"
    echo -e "  ${GREEN}-h, --help${NC}              - ${PURPLE}Display this help message.${NC}"
    echo ""
    echo -e "${YELLOW}Global Options:${NC}"
    echo -e "  ${GREEN}--path <storage_path>${NC} - ${PURPLE}Override default environment storage path for the command.${NC}"
    echo -e "  ${GREEN}--silent${NC}              - ${PURPLE}Run operations silently, showing only errors and essential output.${NC}"
    echo -e "  ${GREEN}--force${NC}               - ${PURPLE}Bypass confirmation prompts (e.g., for 'delete').${NC}"
    echo ""
    echo -e "${YELLOW}Defaults:${NC}"
    echo -e "  ${PURPLE}Default environment storage: ${CYAN}$DEFAULT_PYENV_STORAGE${NC}"
    echo -e "  ${PURPLE}Log file: ${CYAN}$LOG_FILE${NC}"
    echo -e "  ${PURPLE}Configuration file: ${CYAN}$CONFIG_FILE${NC}"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 create myproject_env --path /var/py_envs --silent"
    echo -e "  $0 install myproject_env requirements.txt"
    echo -e "  ${GREEN}source <($0 activate myproject_env)${NC} (THIS IS CRUCIAL FOR ACTIVATION!)"
    echo -e "  $0 -up --silent"
    echo -e "  $0 delete old_env --force"
}

# --- Main Logic ---

# Use getopt to parse arguments
# Long options for --path, --silent, --force, --help, --log, --up
# Short option for -up, -h
# The -o "h" allows -h as a short option.
PARSED_OPTIONS=$(getopt -o "h" -l "path:,silent,force,help,log,up" \
    --name "$0" -- "$@")

# If getopt failed to parse, exit
if [[ $? -ne 0 ]]; then
    # getopt automatically prints an error message
    show_help
    exit 1
fi # <-- CORRECTED: This 'fi' was missing and caused the syntax error.

# Eval the parsed options so they are processed correctly
eval set -- "$PARSED_OPTIONS"

# Process global options (like --silent, --force, --path) first
# Initialize STORAGE_PATH with DEFAULT_PYENV_STORAGE temporarily.
# This will be refined after load_config.
STORAGE_PATH="$DEFAULT_PYENV_STORAGE"
STORAGE_PATH_OVERRIDE="" # To store explicit --path value

while true; do
    case "$1" in
        --path)
            STORAGE_PATH_OVERRIDE="$2" # Capture override
            shift 2
            ;;
        --silent)
            SILENT_MODE=true
            shift
            ;;
        --force)
            FORCE_DELETE=true
            shift
            ;;
        -h|--help)
            # Help is a special case; always show help and exit here, regardless of silent mode.
            show_help
            exit 0
            ;;
        --log)
            # Log is a special case; always show log and exit here, regardless of silent mode.
            # We explicitly echo directly here because `info` depends on SILENT_MODE,
            # and --log should always print, even if --silent was also passed.
            echo -e "${CYAN}Displaying log file: ${CYAN}$LOG_FILE${NC}"
            if [ -f "$LOG_FILE" ]; then
                cat "$LOG_FILE"
            else
                echo -e "${YELLOW}[WARNING]${NC} Log file not found: ${CYAN}$LOG_FILE${NC}"
            fi
            exit 0
            ;;
        --) # End of options
            shift
            break
            ;;
        *)
            # This case handles any non-option arguments that appear before a command.
            # With strict getopt and well-defined options, this should primarily be the COMMAND itself.
            break # Exit loop to handle as command/error
            ;;
    esac
done

# Now that SILENT_MODE is correctly set (from getopt parsing), load configuration.
# This ensures messages from load_config respect the silent mode.
load_config

# Apply the --path override if it was provided, otherwise use the value from config or default.
if [ -n "$STORAGE_PATH_OVERRIDE" ]; then
    STORAGE_PATH="$STORAGE_PATH_OVERRIDE"
fi


# Now, process the actual command
COMMAND="${1:-}" # Get the command (or empty if none)
shift || true # Shift past the command, or do nothing if no command was provided

case "$COMMAND" in
    create)
        if [ -z "$1" ]; then
            error "Missing environment name for 'create' command."
        fi
        ENV_NAME="$1"
        create_env "$ENV_NAME" "$STORAGE_PATH"
        ;;
    delete)
        if [ -z "$1" ]; then
            error "Missing environment name for 'delete' command."
        fi
        ENV_NAME="$1"
        delete_env "$ENV_NAME" "$STORAGE_PATH"
        ;;
    install)
        if [ -z "$1" ] || [ -z "$2" ]; then
            error "Missing environment name or requirements file for 'install' command."
        fi
        ENV_NAME="$1"
        REQ_FILE="$2"
        install_packages "$ENV_NAME" "$REQ_FILE" "$STORAGE_PATH"
        ;;
    export)
        if [ -z "$1" ] || [ -z "$2" ]; then
            error "Missing environment name or output file for 'export' command."
        fi
        ENV_NAME="$1"
        OUTPUT_FILE="$2"
        export_requirements "$ENV_NAME" "$OUTPUT_FILE" "$STORAGE_PATH"
        ;;
    list)
        list_envs "$STORAGE_PATH"
        ;;
    activate)
        if [ -z "$1" ]; then
            error "Missing environment name for 'activate' command."
        fi
        ENV_NAME="$1"
        activate_env "$ENV_NAME" "$STORAGE_PATH"
        ;;
    check-update-python|-up|--up)
        check_python_update
        ;;
    "") # If no command was provided after global options (e.g., just `./python.sh` or `./python.sh --silent`)
        show_help
        ;;
    *)
        error "Unknown command: ${BLUE}$COMMAND${NC}. Use '$0 --help' for usage."
        ;;
esac