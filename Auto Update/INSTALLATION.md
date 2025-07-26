# QNAP Installation Guide

Follow these steps to install the Docker Auto-Update system on your QNAP NAS.

## Prerequisites

- QNAP NAS with Container Station installed
- SSH access enabled on your QNAP
- Admin or user with Docker permissions

## Step 1: Enable SSH on QNAP

1. Open QNAP web interface
2. Go to **Control Panel** → **Network & File Services** → **Telnet / SSH**
3. Check **Allow SSH connection**
4. Set port (default 22) and click **Apply**

## Step 2: Copy Files to QNAP

### Option A: Using SCP (Recommended)
From your local machine terminal:

```bash
# Replace 'your-qnap-ip' with your actual QNAP IP address
# Replace 'admin' with your QNAP username if different

scp -r "/Users/warrencammack/Documents/GitHub/qnap" admin@10.1.1.5:/share/homes/admin/
```

### Option B: Using File Station
1. Open QNAP File Station
2. Navigate to your home directory
3. Create folder called `qnap`
4. Upload all files from your local `qnap` folder

## Step 3: SSH into QNAP and Setup

```bash
# Connect to your QNAP
ssh admin@your-qnap-ip

# Navigate to the project directory
cd /share/homes/admin/qnap/Auto\ Update

# Make scripts executable
chmod +x auto-update.sh
chmod +x setup-cron.sh

# Verify files are present
ls -la
```

## Step 4: Configure Slack Notifications (Optional)

```bash
# Edit the configuration file
nano config.yaml

# Update this line with your Slack webhook URL:
# webhook_url: "YOUR_SLACK_WEBHOOK_URL_HERE"
# 
# Save and exit: Ctrl+X, then Y, then Enter
```

**To get a Slack webhook URL:**
1. Go to https://api.slack.com/apps
2. Create a new app or select existing one
3. Go to **Incoming Webhooks**
4. Click **Add New Webhook to Workspace**
5. Choose channel and copy the webhook URL

## Step 5: Test the Installation

```bash
# Run a test update (this will update all containers immediately)
./auto-update.sh

# Check the log file for results
cat auto-update.log
```

## Step 6: Install Weekly Cron Job

```bash
# Install the automated weekly schedule
./setup-cron.sh

# Verify cron job was added
crontab -l
```

## Step 7: Verify Container Paths

The script assumes your Docker Compose files are in:
```
/share/homes/admin/qnap/Composer/
```

If your files are in a different location, edit the script:
```bash
nano auto-update.sh
# Change the COMPOSER_DIR variable to your actual path
```

## Troubleshooting

### Permission Issues
```bash
# If you get permission errors, try:
sudo chmod +x auto-update.sh setup-cron.sh
```

### Docker Command Not Found
```bash
# Check if docker-compose is installed
which docker-compose

# If not found, install it:
# Follow QNAP Container Station documentation
```

### Path Issues
```bash
# Verify your Composer files location
ls -la /share/homes/admin/qnap/Composer/

# If different, update the COMPOSER_DIR in auto-update.sh
```

### Cron Not Working
```bash
# Check if cron service is running
ps aux | grep cron

# View cron logs
tail -f cron.log
```

## File Locations After Installation

```
/share/homes/admin/qnap/
├── Auto Update/
│   ├── auto-update.sh          # Main script
│   ├── config.yaml             # Configuration
│   ├── setup-cron.sh           # Cron installer
│   ├── auto-update.log         # Update logs
│   ├── cron.log               # Cron logs
│   └── README.md              # Documentation
└── Composer/
    ├── sonarr.yaml            # Your existing compose files
    ├── radarr.yaml
    └── ...
```

## Maintenance

### View Logs
```bash
# Live update logs
tail -f /share/homes/admin/qnap/Auto\ Update/auto-update.log

# Cron execution logs
tail -f /share/homes/admin/qnap/Auto\ Update/cron.log
```

### Manual Updates
```bash
# Run update manually anytime
cd /share/homes/admin/qnap/Auto\ Update
./auto-update.sh
```

### Modify Schedule
```bash
# Edit cron schedule
crontab -e

# Current schedule: Every Sunday at 2:00 AM
# Format: minute hour day month weekday command
# 0 2 * * 0 = Sunday at 2:00 AM
```

## Support

If you encounter issues:
1. Check the log files first
2. Verify Docker and docker-compose are working
3. Ensure file paths are correct
4. Test Slack webhook manually if notifications aren't working

The system will automatically:
- Update all containers weekly
- Roll back failed updates
- Send Slack notifications
- Keep detailed logs
- Only run during maintenance window (2-6 AM)