#!/bin/bash

# QNAP Deployment Script
# Automates copying files and setting up the auto-update system

set -euo pipefail  # Exit on error, unbound variables, and pipeline failures

# Configuration
QNAP_IP="10.1.1.5"
QNAP_USER="admin"
SSH_KEY="$HOME/.ssh/qnap_rsa_key"
LOCAL_REPO="/Users/warrencammack/Documents/GitHub/Personal/qnap"
REMOTE_BASE="/share/CACHEDEV1_DATA/homes/admin"
REMOTE_DIR="${REMOTE_BASE}/qnap"
AUTO_UPDATE_DIR="${REMOTE_DIR}/Auto Update"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check SSH connectivity
check_ssh_connection() {
    print_info "Testing SSH connection to QNAP..."
    if ssh -i "$SSH_KEY" -o ConnectTimeout=10 ${QNAP_USER}@${QNAP_IP} "echo 'Connection successful'" > /dev/null 2>&1; then
        print_info "SSH connection successful"
        return 0
    else
        print_error "Cannot connect to QNAP via SSH"
        print_warn "Please ensure:"
        echo "  1. SSH is enabled on QNAP (Control Panel > Network & File Services > Telnet/SSH)"
        echo "  2. SSH key exists at ~/.ssh/qnap_rsa_key"
        echo "  3. QNAP IP address is correct: ${QNAP_IP}"
        return 1
    fi
}

# Function to copy files to QNAP using rsync (more reliable than scp for QNAP)
copy_files() {
    print_info "Copying files to QNAP..."

    # Try rsync first (more reliable for QNAP)
    if command -v rsync &> /dev/null; then
        print_info "Using rsync to copy files..."
        if rsync -avz -e "ssh -i $SSH_KEY" "${LOCAL_REPO}" ${QNAP_USER}@${QNAP_IP}:${REMOTE_BASE}/; then
            print_info "Files copied successfully via rsync"
            return 0
        else
            print_warn "rsync failed, trying alternative method..."
        fi
    fi

    # Fallback: Use tar over SSH (works when SCP subsystem fails)
    print_info "Using tar over SSH to copy files..."
    if tar -czf - -C "$(dirname "${LOCAL_REPO}")" "$(basename "${LOCAL_REPO}")" | \
       ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "cd ${REMOTE_BASE} && tar -xzf -"; then
        print_info "Files copied successfully via tar over SSH"
        return 0
    else
        print_error "Failed to copy files to QNAP"
        print_warn "Possible solutions:"
        echo "  1. Check if SCP/SFTP subsystem is enabled on QNAP"
        echo "  2. Try manually: ssh -i $SSH_KEY ${QNAP_USER}@${QNAP_IP}"
        echo "  3. Use File Station to upload files manually"
        return 1
    fi
}

# Function to setup scripts on QNAP
setup_scripts() {
    print_info "Setting up scripts on QNAP..."

    ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} bash <<'ENDSSH'
        set -e

        # Navigate to Auto Update directory
        cd "/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update"

        # Make scripts executable
        chmod +x auto-update.sh
        chmod +x setup-cron.sh
        chmod +x image-cleanup.sh
        chmod +x setup-image-cleanup-cron.sh

        echo "Scripts made executable"

        # Verify files are present
        echo ""
        echo "Files in Auto Update directory:"
        ls -lh

        echo ""
        echo "Setup complete!"
ENDSSH

    if [ $? -eq 0 ]; then
        print_info "Scripts setup successfully"
        return 0
    else
        print_error "Failed to setup scripts"
        return 1
    fi
}

# Function to run test update (optional)
run_test_update() {
    print_warn "Would you like to run a test update now? This will update all containers."
    read -p "Run test update? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Running test update..."
        ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "cd '/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update' && ./auto-update.sh"
        print_info "Test update complete. Check the log:"
        ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "tail -20 '/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update/auto-update.log'"
    else
        print_info "Skipping test update"
    fi
}

# Function to install cron job (optional)
install_cron() {
    print_warn "Would you like to install the weekly cron job (Sunday 2AM)?"
    read -p "Install cron job? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Installing cron job..."
        ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "cd '/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update' && ./setup-cron.sh"

        print_info "Verifying cron job installation..."
        ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "crontab -l"
    else
        print_info "Skipping cron installation"
    fi
}

# Function to install image cleanup cron (optional)
install_image_cleanup_cron() {
    print_warn "Would you like to install the weekly image cleanup cron job (Sunday 3AM)?"
    read -p "Install image cleanup cron job? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Installing image cleanup cron job..."
        ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "cd '/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update' && ./setup-image-cleanup-cron.sh"

        print_info "Verifying cron job installation..."
        ssh -i "$SSH_KEY" ${QNAP_USER}@${QNAP_IP} "crontab -l"
    else
        print_info "Skipping image cleanup cron installation"
    fi
}

# Main deployment flow
main() {
    echo "======================================"
    echo "  QNAP Auto-Update Deployment Script"
    echo "======================================"
    echo ""

    # Check if local repository exists
    if [ ! -d "${LOCAL_REPO}" ]; then
        print_error "Local repository not found at: ${LOCAL_REPO}"
        exit 1
    fi

    print_info "Local repository: ${LOCAL_REPO}"
    print_info "Target QNAP: ${QNAP_USER}@${QNAP_IP}"
    print_info "Remote directory: ${REMOTE_DIR}"
    echo ""

    # Step 1: Check SSH connection
    if ! check_ssh_connection; then
        exit 1
    fi
    echo ""

    # Step 2: Copy files
    if ! copy_files; then
        exit 1
    fi
    echo ""

    # Step 3: Setup scripts
    if ! setup_scripts; then
        exit 1
    fi
    echo ""

    # Optional: Run test update
    run_test_update
    echo ""

    # Optional: Install cron job
    install_cron
    echo ""

    # Optional: Install image cleanup cron
    install_image_cleanup_cron
    echo ""

    print_info "======================================"
    print_info "Deployment complete!"
    print_info "======================================"
    echo ""
    echo "Next steps:"
    echo "  1. Configure Slack webhook in config.yaml (if desired)"
    echo "  2. SSH to QNAP: ssh -i $SSH_KEY ${QNAP_USER}@${QNAP_IP}"
    echo "  3. Edit config: cd '/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update' && nano config.yaml"
    echo "  4. View logs: tail -f '/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update/auto-update.log'"
    echo ""
    print_warn "Don't forget to disable SSH on QNAP when finished (Control Panel > Network & File Services > Telnet/SSH)"
}

# Run main function
main
