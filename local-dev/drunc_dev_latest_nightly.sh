#!/bin/bash

# DUNE-DAQ development environment setup script
# Creates a new DAQ project, clones required repositories, and configures VS Code settings

set -e  # Exit immediately if a command exits with a non-zero status
set -o pipefail  # Return value of a pipeline is the status of the last command to exit with a non-zero status

# Colour codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No colour

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Error logging function
error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Warning logging function
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Generate project name from current date
PROJECT_NAME="$(date +'%d-%m-%Y')-daq-nightly-workspace"

# Main execution with error handling
main() {
    log "Starting DUNE-DAQ setup with project name: ${PROJECT_NAME}"
    
    # Source DUNE-DAQ environment
    log "Sourcing DUNE-DAQ environment..."
    if ! source /cvmfs/dunedaq.opensciencegrid.org/setup_dunedaq.sh; then
        error "Failed to source DUNE-DAQ environment"
        return 1
    fi
    
    # Setup DBT
    log "Setting up DBT (latest version)..."
    if ! setup_dbt latest; then
        error "Failed to setup DBT"
        return 1
    fi

    # The current DUNE nightly provides its 'systems' package for AlmaLinux 9,
    # while DBT automatically detects AlmaLinux 10 on AlmaLinux 10 hosts. 
    #Override the target only on AlmaLinux 10.
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "${ID}" = "almalinux" ] && [[ "${VERSION_ID}" == 10* ]]; then
            export DBT_ARCH=linux-almalinux9-x86_64
            log "AlmaLinux 10 detected; setting DBT_ARCH=${DBT_ARCH}"
        fi
    fi
        
    # Create DAQ project
    log "Creating DAQ project: ${PROJECT_NAME}..."
    if ! dbt-create -n last_fddaq "${PROJECT_NAME}"; then
        error "Failed to create DAQ project"
        return 1
    fi
    
    # Navigate to project directory
    log "Entering project directory..."
    if ! cd "${PROJECT_NAME}"; then
        error "Failed to enter project directory"
        return 1
    fi
    
    # Source project environment
    log "Sourcing project environment..."
    if ! . env.sh; then
        error "Failed to source project environment"
        return 1
    fi
    
    # Build project
    log "Building project..."
    if ! dbt-build; then
        error "Failed to build project"
        return 1
    fi
    
    # Navigate to source code directory
    log "Entering sourcecode directory..."
    if ! cd sourcecode; then
        error "Failed to enter sourcecode directory"
        return 1
    fi
    
    # Clone required repositories
    log "Cloning drunc repository..."
    if ! git clone https://github.com/DUNE-DAQ/drunc.git; then
        error "Failed to clone drunc repository"
        return 1
    fi
    
    log "Cloning druncschema repository..."
    if ! git clone https://github.com/DUNE-DAQ/druncschema.git; then
        error "Failed to clone druncschema repository"
        return 1
    fi
    
    log "Cloning daqsystemtest repository..."
    if ! git clone https://github.com/DUNE-DAQ/daqsystemtest.git; then
        error "Failed to clone daqsystemtest repository"
        return 1
    fi
    
    # Configure VS Code settings for drunc repo
    log "Creating VS Code configuration for drunc..."
    if ! mkdir -p drunc/.vscode; then
        error "Failed to create .vscode directory"
        return 1
    fi
    
    # Install drunc package in development mode with dev dependencies
    log "Installing drunc in development mode..."
    if ! (cd drunc && pip install -e .[dev]); then
        error "Failed to install drunc in development mode"
	return 1
    fi

    # Install pre-commit hooks for drunc repository
    log "Installing pre-commit hooks for drunc..."
    if ! (cd drunc && pre-commit install); then
        warn "Failed to install pre-commit hooks (pre-commit may not be installed)"
    fi
      
    # Write VS Code settings file
    cat > drunc/.vscode/settings.json << 'EOF'
{
    "python.testing.pytestArgs": [
        "tests"
    ],
    "python.testing.unittestEnabled": false,
    "python.testing.pytestEnabled": true,
    "editor.formatOnSave": true,
    "editor.defaultFormatter": "charliermarsh.ruff",
    "[python]": {
        "editor.codeActionsOnSave": {
            "source.fixAll.ruff": "explicit",
            "source.organizeImports.ruff": "explicit"
        }
    },
    "[Log]": {
        "editor.wordWrap": "on"
    },
    "debug.console.wordWrap": true
}
EOF
    
    if [ $? -ne 0 ]; then
        error "Failed to write VS Code settings file"
        return 1
    fi
    
    log "Setup completed successfully!"
    log "Project location: ${PROJECT_NAME}/sourcecode"
    
    return 0
}

# Execute main function and capture exit status
if main; then
    exit 0
else
    error "Setup failed. Please review the errors above."
    exit 1
fi
