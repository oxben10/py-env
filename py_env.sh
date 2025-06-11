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
DEFAULT_PYENV_STORAGE="$HOME/.pyenvs"
LOG_FILE="$HOME/.pyenv_manager.log"

SILENT_MODE=false # Default to non-silent mode
FORCE_DELETE=false # Default to requiring confirmation for deletion


# --- Helper Functions for Logging and Output ---

# Centralized logging and terminal output function
log_message() {
    local type="$1"
    local raw_message="$2" # Message without color codes for logging
    local colored_message="$3" # Message with color codes for terminal display

    # Ensure log file directory exists before writing
    mkdir -p "$(dirname "$LOG_FILE")" || error "Failed to create log directory: $(dirname "$LOG_FILE")"

    # Log to file (always raw, no colors)
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$type] $raw_message" >> "$LOG_FILE"

    # Print to terminal if not in silent mode
    if ! $SILENT_MODE; then
        echo -e "$colored_message"
    fi
}

success() {
    local message="$1"
    log_message "SUCCESS" "[SUCCESS] $message" "${GREEN}[SUCCESS]${NC} $message"
}

info() {
    local message="$1"
    log_message "INFO" "[INFO] $message" "${CYAN}[INFO]${NC} $message"
}

warning() {
    local message="$1"
    log_message "WARNING" "[WARNING] $message" "${YELLOW}[WARNING]${NC} $message"
}

error() {
    local message="$1"
    # Errors always print to terminal, regardless of SILENT_MODE
    echo -e "${RED}[ERROR]${NC} $message"
    log_message "ERROR" "[ERROR] $message" "${RED}[ERROR]${NC} $message" # Log error with color for consistency
    exit 1
}

# Function to compare version numbers (major.minor.patch)
# Returns 0 if v1 >= v2, 1 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    # Normalize versions by replacing '-' with '.' and padding with .0 if needed
    v1_norm=$(echo "$v1" | sed 's/-/./g' | awk -F'.' '{printf "%s.%s.%s", $1,$2,$3?$3:"0"}' )
    v2_norm=$(echo "$v2" | sed 's/-/./g' | awk -F'.' '{printf "%s.%s.%s", $1,$2,$3?$3:"0"}' )

    if printf '%s\n%s\n' "$v1_norm" "$v2_norm" | sort -V -C; then
        return 0 # v1 >= v2
    else
        return 1 # v1 < v2
    fi
}


check_python_pip() {
    info "Checking for Python and pip..."

    local install_needed=false

    # --- Check Python 3 ---
    if ! command -v python3 &> /dev/null; then
        warning "Python 3 not found. It will be installed."
        install_needed=true
    else
        success "Python 3 is already installed."
    fi

    # --- Check pip3 ---
    if ! command -v pip3 &> /dev/null; then
        warning "pip3 not found. It will be installed."
        install_needed=true
    else
        success "pip3 is already installed."
    fi

    if [ "$install_needed" = true ]; then
        info "Attempting to install missing Python 3 and/or pip3."
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
            # Arch uses 'python' for Python 3 by default, and 'python-pip'
            sudo pacman -Sy python python-pip || error "Failed to install python and pip using pacman."
        else
            error "Python 3 and pip not found, and cannot determine package manager to install them automatically. Please install Python 3 and pip manually."
        fi
        success "Python 3 and pip installation/check complete."
    else
        info "No core Python 3 or pip3 installation needed at this time."
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
    log_message "INFO" "Activation command for '${env_name}': source \"$env_path/bin/activate\"" "" # No color for log
}

check_python_update() {
    info "Initiating Python and Pip update check..."

    # --- Check Python 3 ---
    if ! command -v python3 &> /dev/null; then
        warning "Python 3 is not installed on this system. Cannot check for updates."
    else
        local current_python_version=$(python3 --version 2>&1 | awk '{print $2}')
        success "Current system Python 3 version: ${GREEN}$current_python_version${NC}"

        local package_manager=""
        local python_package_name=""
        local pip_package_name=""

        if command -v apt-get &> /dev/null; then
            package_manager="apt"
            python_package_name="python3"
            pip_package_name="python3-pip"
            info "Running 'sudo apt-get update' to refresh package lists..."
            sudo apt-get update > /dev/null 2>&1 || warning "Failed to update apt package lists."

            local available_python_version=$(apt-cache policy python3 | grep Candidate | awk '{print $2}' | cut -d'-' -f1 || echo "")
            if [ -n "$available_python_version" ]; then
                info "Latest Python 3 version available via apt: ${CYAN}$available_python_version${NC}"
                if compare_versions "$available_python_version" "$current_python_version"; then
                    success "System Python 3 is already at or above the version available in apt repositories."
                else
                    warning "A newer Python 3 version (${available_python_version}) is available via apt."
                    if ! $SILENT_MODE; then
                        echo -e "${YELLOW}To upgrade system Python 3, run: ${PURPLE}sudo apt-get install --only-upgrade python3${NC}"
                    fi
                fi
            else
                info "Could not determine latest Python 3 version from apt repositories or no updates available."
            fi

        elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
            package_manager=$(command -v dnf || echo "yum") # Prefer dnf if available
            python_package_name="python3"
            pip_package_name="python3-pip"
            info "Running 'sudo $package_manager check-update' to refresh package lists..."
            sudo $package_manager check-update > /dev/null 2>&1 || warning "Failed to check for updates with $package_manager."

            local upgradable_python=$(sudo $package_manager list updates 2>/dev/null | grep -E "^python3\." | awk '{print $2}' | head -n 1 || echo "")
            if [ -n "$upgradable_python" ]; then
                warning "An update for Python 3 (${upgradable_python}) is available via $package_manager."
                if ! $SILENT_MODE; then
                    echo -e "${YELLOW}To upgrade system Python 3, run: ${PURPLE}sudo $package_manager update python3${NC}"
                fi
            else
                success "System Python 3 is up to date in $package_manager repositories."
            fi

        elif command -v pacman &> /dev/null; then
            package_manager="pacman"
            python_package_name="python" # Arch Linux uses 'python' for Python 3
            pip_package_name="python-pip"
            info "Running 'sudo pacman -Sy' to refresh package lists..."
            sudo pacman -Sy > /dev/null 2>&1 || warning "Failed to update pacman package lists."

            local upgradable_python=$(pacman -Qu 2>/dev/null | grep -E "^python " | awk '{print $4}' | head -n 1 || echo "")
            if [ -n "$upgradable_python" ]; then
                warning "An update for Python 3 (${upgradable_python}) is available via pacman."
                if ! $SILENT_MODE; then
                    echo -e "${YELLOW}To upgrade system Python 3, run: ${PURPLE}sudo pacman -Syu${NC}"
                fi
            else
                success "System Python 3 is up to date in pacman repositories."
            fi
        else
            info "Unable to determine system's package manager to check for Python 3 updates. Please check manually."
        fi
    fi

    echo # Newline for readability

    # --- Check pip3 ---
    if ! command -v pip3 &> /dev/null; then
        warning "pip3 is not installed on this system. Cannot check for updates."
    else
        local current_pip_version=$(pip3 --version 2>&1 | awk '{print $2}')
        success "Current system pip3 version: ${GREEN}$current_pip_version${NC}"

        info "Checking for pip3 updates via package manager..."
        if [ -n "$package_manager" ]; then
            if [ "$package_manager" = "apt" ]; then
                local available_pip_version=$(apt-cache policy python3-pip | grep Candidate | awk '{print $2}' | cut -d'-' -f1 || echo "")
                if [ -n "$available_pip_version" ]; then
                    info "Latest pip3 version available via apt: ${CYAN}$available_pip_version${NC}"
                    if compare_versions "$available_pip_version" "$current_pip_version"; then
                        success "System pip3 is already at or above the version available in apt repositories."
                    else
                        warning "A newer pip3 version (${available_pip_version}) is available via apt."
                        if ! $SILENT_MODE; then
                            echo -e "${YELLOW}To upgrade system pip3, run: ${PURPLE}sudo apt-get install --only-upgrade python3-pip${NC}"
                        fi
                    fi
                else
                    info "Could not determine latest pip3 version from apt repositories or no updates available."
                fi
            elif [ "$package_manager" = "yum" ] || [ "$package_manager" = "dnf" ]; then
                local upgradable_pip=$(sudo $package_manager list updates 2>/dev/null | grep -E "^python3-pip" | awk '{print $2}' | head -n 1 || echo "")
                if [ -n "$upgradable_pip" ]; then
                    warning "An update for pip3 (${upgradable_pip}) is available via $package_manager."
                    if ! $SILENT_MODE; then
                        echo -e "${YELLOW}To upgrade system pip3, run: ${PURPLE}sudo $package_manager update python3-pip${NC}"
                    fi
                else
                    success "System pip3 is up to date in $package_manager repositories."
                fi
            elif [ "$package_manager" = "pacman" ]; then
                local upgradable_pip=$(pacman -Qu 2>/dev/null | grep -E "^python-pip " | awk '{print $4}' | head -n 1 || echo "")
                if [ -n "$upgradable_pip" ]; then
                    warning "An update for pip3 (${upgradable_pip}) is available via pacman."
                    if ! $SILENT_MODE; then
                        echo -e "${YELLOW}To upgrade system pip3, run: ${PURPLE}sudo pacman -Syu${NC}"
                    fi
                else
                    success "System pip3 is up to date in pacman repositories."
                fi
            fi
        fi

        # Suggest direct pip upgrade for the absolute latest from PyPI
        if ! $SILENT_MODE; then
            echo ""
            info "To upgrade pip3 to the absolute latest version from PyPI (Python Package Index), run:"
            echo -e "${PURPLE}  python3 -m pip install --upgrade pip${NC}"
        fi
    fi

    echo ""
    warning "System-wide Python/Pip updates can sometimes affect system tools. Use virtual environments for project-specific Python versions."
    info "For managing multiple Python versions and the absolute latest releases without system-wide interference, consider using a tool like ${BLUE}pyenv${NC} (https://github.com/pyenv/pyenv)."
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
    echo -e "  ${GREEN}list${NC}                        - ${PURPLE}List all virtual environments.${NC}"
    echo -e "  ${GREEN}activate <env_name>${NC}       - ${PURPLE}Display command to activate a virtual environment. Requires 'source'!${NC}"
    echo -e "  ${GREEN}check-update-python${NC}       - ${PURPLE}Check if the system's Python 3 and pip3 installations have updates.${NC}"
    echo -e "  ${GREEN}-check-update-python, --up${NC}              - ${PURPLE}Alias for check-update-python.${NC}"
    echo -e "  ${GREEN}--log${NC}                     - ${PURPLE}View the log file.${NC}"
    echo -e "  ${GREEN}-h, --help${NC}                - ${PURPLE}Display this help message.${NC}"
    echo ""
    echo -e "${YELLOW}Global Options:${NC}"
    echo -e "  ${GREEN}--path <storage_path>${NC} - ${PURPLE}Override default environment storage path for the command.${NC}"
    echo -e "  ${GREEN}--silent${NC}              - ${PURPLE}Run operations silently, showing only errors and essential output.${NC}"
    echo -e "  ${GREEN}--force${NC}               - ${PURPLE}Bypass confirmation prompts (e.g., for 'delete').${NC}"
    echo ""
    echo -e "${YELLOW}Defaults:${NC}"
    echo -e "  ${PURPLE}Default environment storage: ${CYAN}$DEFAULT_PYENV_STORAGE${NC}"
    echo -e "  ${PURPLE}Log file: ${CYAN}$LOG_FILE${NC}"
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
fi

# Eval the parsed options so they are processed correctly
eval set -- "$PARSED_OPTIONS"

# Process global options (like --silent, --force, --path) first
# Initialize STORAGE_PATH with DEFAULT_PYENV_STORAGE.
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

# Apply the --path override if it was provided, otherwise use the default.
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