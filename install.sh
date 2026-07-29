#!/bin/bash

# ==============================================================================
# ArcaPass - Raspberry Pi Zero Deployment Script
# ==============================================================================
# Run this script from the root of the Arca project folder on your Raspberry Pi:
# sudo bash deployment/install.sh
# ==============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo: sudo bash deployment/install.sh"
  exit 1
fi

# Enable strict error handling
set -e

# Error handler function
error_handler() {
    echo ""
    echo "====================================================================="
    echo "❌ FATAL ERROR: Installation aborted!"
    echo "An unexpected error occurred at line \${BASH_LINENO[0]}."
    echo "Please review the log output above to identify the problem and try again."
    echo "====================================================================="
    exit 1
}

# Trap ERR to trigger the error_handler
trap 'error_handler' ERR

echo "🚀 Starting Arca deployment for Raspberry Pi..."

INSTALL_DIR="/opt/arca"
if [ -n "$SUDO_USER" ]; then
    APP_USER="$SUDO_USER"
else
    APP_USER=$(whoami)
fi

# 1. Update and install system dependencies
echo "📦 Installing system dependencies (Python3, Nginx, SQLite)..."
apt-get update
apt-get install -y python3 python3-venv python3-pip python3-dev build-essential libffi-dev nginx sqlite3 ufw

# 2. Source Code Retrieval
echo "📁 Setting up codebase in $INSTALL_DIR..."
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p $INSTALL_DIR
fi

read -p "Do you want to download the codebase directly from your GitHub repository? (y/n) [y]: " CLONE_GH
CLONE_GH=${CLONE_GH:-y}

if [ "$CLONE_GH" == "y" ]; then
    GH_URL="https://github.com/rajshahmusic/arca_api.git"
    
    echo "⬇️ Cloning repository..."
    # Attempt to install gh if not present (might require GitHub's official apt repo on older systems)
    apt-get install -y git gh
    # If the user ran with sudo, run gh as the original user so it uses their authentication
    if [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" gh repo clone "$GH_URL" $INSTALL_DIR/temp_clone
    else
        gh repo clone "$GH_URL" $INSTALL_DIR/temp_clone
    fi
    cp -a $INSTALL_DIR/temp_clone/. $INSTALL_DIR/
    rm -rf $INSTALL_DIR/temp_clone
else
    # Copy everything from current directory to /opt/arca
    echo "Moving local files to $INSTALL_DIR..."
    cp -a . $INSTALL_DIR/
fi

# Ensure the dist folder exists (warn if frontend hasn't been built)
if [ ! -d "$INSTALL_DIR/frontend/dist" ]; then
    echo "⚠️  WARNING: frontend/dist not found!"
    echo "   You should run 'npm run build' inside the frontend folder on your PC"
    echo "   and transfer the dist folder to the Pi. The web interface will not load without it."
fi

# 3. Setup Python Virtual Environment
echo "🐍 Setting up Python Virtual Environment..."
cd $INSTALL_DIR
python3 -m venv arcaenv
source arcaenv/bin/activate
echo "⬇️ Installing Python packages (this might take a few minutes on a Pi Zero)..."
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# 4. Set Permissions
echo "🔒 Setting permissions..."
chown -R $APP_USER:www-data $INSTALL_DIR
chmod -R 775 $INSTALL_DIR
# Ensure the database can be written to by the API (www-data group)
if [ -f "$INSTALL_DIR/database.db" ]; then
    chmod 664 $INSTALL_DIR/database.db
fi

# 5. Configure Nginx Reverse Proxy
echo "🌐 Configuring Nginx..."
cp $INSTALL_DIR/deployment/arca.conf /etc/nginx/sites-available/arca
# Remove default nginx site if it exists
if [ -f "/etc/nginx/sites-enabled/default" ]; then
    rm /etc/nginx/sites-enabled/default
fi
# Enable Arca site
if [ ! -f "/etc/nginx/sites-enabled/arca" ]; then
    ln -s /etc/nginx/sites-available/arca /etc/nginx/sites-enabled/
fi
# Test and restart Nginx
nginx -t && systemctl restart nginx

# 6. Configure Systemd Service for Uvicorn
echo "⚙️ Configuring Systemd Service..."
cp $INSTALL_DIR/deployment/arca.service /etc/systemd/system/
sed -i "s/User=pi/User=$APP_USER/g" /etc/systemd/system/arca.service
systemctl daemon-reload
systemctl enable arca.service
systemctl start arca.service

# 7. Setup .env file via Interactive Wizard
while true; do
    echo "====================================================================="
    echo "⚙️  Network Configuration Wizard"
    echo "====================================================================="
    echo "Arca Passkeys require a Secure Context (HTTPS) to function correctly."
    echo "Please select how you will securely route traffic to this Raspberry Pi:"
    echo "  [1] Ngrok (Free Public URL - Recommended for external access)"
    echo "  [2] Tailscale MagicDNS (e.g., pi.your-tailnet.ts.net)"
    echo "  [3] Local Network / Self-Signed (e.g., 192.168.1.100 or localhost)"
    echo "  [0] Cancel Installation"
    echo ""

    read -p "Select an option [0-3]: " ROUTE_OPT

    if [ "$ROUTE_OPT" == "0" ]; then
        echo "❌ Installation cancelled by user."
        exit 0
    fi

    if [ "$ROUTE_OPT" == "1" ]; then
        echo ""
        echo "====================================================================="
        echo "🌐 Option 1: Ngrok Configuration"
        echo "====================================================================="
        echo "Ngrok gives you a completely free, permanent public URL so you can"
        echo "access Arca from anywhere in the world without a VPN."
        echo ""
        echo "1. Go to https://ngrok.com and create a free account."
        echo "2. In your dashboard, find your 'Authtoken'."
        echo "3. Go to Cloud Edge -> Domains to find your 'Free Static Domain'."
        echo ""
        read -p "Would you like to proceed with Ngrok? (y/n) [y] or type 'back' to return: " PROCEED
        if [ "$PROCEED" == "back" ] || [ "$PROCEED" == "n" ]; then
            echo ""
            continue
        fi
        
        read -p "Enter your Ngrok Authtoken: " NGROK_TOKEN
        read -p "Enter your Ngrok Domain (e.g., renewed-monster.ngrok-free.app): " RP_ID
        break
    elif [ "$ROUTE_OPT" == "2" ]; then
        echo ""
        echo "====================================================================="
        echo "🐉 Option 2: Tailscale MagicDNS"
        echo "====================================================================="
        echo "Tailscale connects all your devices into a private, secure VPN."
        echo "It will automatically assign a magic domain to this device."
        echo ""
        read -p "Would you like to proceed with Tailscale? (y/n) [y] or type 'back' to return: " PROCEED
        if [ "$PROCEED" == "back" ] || [ "$PROCEED" == "n" ]; then
            echo ""
            continue
        fi
        
        read -p "Enter your exact Tailscale domain/IP (WITHOUT https:// or trailing slashes, e.g., 'pi.tailnet.ts.net'): " RP_ID
        break
    elif [ "$ROUTE_OPT" == "3" ]; then
        echo ""
        echo "====================================================================="
        echo "🏠 Option 3: Local Network"
        echo "====================================================================="
        echo "Run Arca entirely locally. If you choose this, passkeys may only work"
        echo "if accessed via 'localhost' directly (unless you setup self-signed certs)."
        echo ""
        read -p "Would you like to proceed with Local Network? (y/n) [y] or type 'back' to return: " PROCEED
        if [ "$PROCEED" == "back" ] || [ "$PROCEED" == "n" ]; then
            echo ""
            continue
        fi
        
        read -p "Enter your exact domain/IP (e.g., '192.168.1.100' or 'localhost'): " RP_ID
        break
    else
        echo "❌ Invalid option selected. Please try again."
        echo ""
    fi
done

if [ "$ROUTE_OPT" == "3" ] && [ "$RP_ID" == "localhost" ]; then
    EXPECTED_ORIGIN="http://localhost"
else
    EXPECTED_ORIGIN="https://$RP_ID"
fi

TUNNEL_MSG=""

if [ "$ROUTE_OPT" == "1" ]; then
    echo "☁️ Installing Ngrok..."
    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | tee /etc/apt/keyrings/ngrok.asc >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/ngrok.asc] https://ngrok-agent.s3.amazonaws.com buster main" | tee /etc/apt/sources.list.d/ngrok.list
    apt-get update
    apt-get install -y ngrok

    echo "🔑 Authenticating Ngrok..."
    ngrok config add-authtoken "$NGROK_TOKEN"

    echo "⚙️ Creating Ngrok Systemd Service..."
    cat <<EOF > /etc/systemd/system/ngrok.service
[Unit]
Description=Ngrok Tunnel for Arca
After=network.target nginx.service

[Service]
User=root
ExecStart=/usr/bin/ngrok http --url=https://$RP_ID --host-header="localhost" 80
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ngrok
    systemctl start ngrok

    TUNNEL_MSG="Ngrok is running. Your Arca instance is live at: https://$RP_ID"
elif [ "$ROUTE_OPT" == "2" ]; then
    echo "🐉 Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    TUNNEL_MSG="Run 'sudo tailscale up' to connect your Pi to your Tailnet."
fi

echo "📝 Generating .env configuration..."
SECRET=$(openssl rand -hex 32)

cat <<EOF > $INSTALL_DIR/.env
SECRET_KEY=$SECRET
RP_ID=$RP_ID
RP_EXPECTED_ORIGIN=$EXPECTED_ORIGIN
BACKEND_CORS_ORIGINS=["$EXPECTED_ORIGIN"]
EOF

echo "🗄️ Initializing database..."
source "$INSTALL_DIR/arcaenv/bin/activate"
cd "$INSTALL_DIR"
alembic upgrade head
deactivate

chown $APP_USER:www-data $INSTALL_DIR/.env

# 8. Auto-Updates (Cronjob)
echo "====================================================================="
echo "🔄 Auto-Updates"
echo "====================================================================="
read -p "Do you want Arca to automatically pull updates from GitHub every night at 3 AM? (y/n) [n]: " AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-n}

if [ "$AUTO_UPDATE" == "y" ]; then
    echo "📅 Setting up nightly cronjob..."
    echo "0 3 * * * root bash $INSTALL_DIR/deployment/backup.sh > /var/log/arca_backup.log 2>&1 && bash $INSTALL_DIR/deployment/update.sh > /var/log/arca_update.log 2>&1" > /etc/cron.d/arca_update
    chmod 644 /etc/cron.d/arca_update
    echo "✅ Auto-updates enabled!"
else
    echo "Auto-updates disabled. You can manually update anytime by running: sudo bash $INSTALL_DIR/deployment/update.sh"
fi

echo "====================================================================="
echo "✅ Arca Installation Complete!"
echo "====================================================================="
echo ""
echo "Next steps:"
if [ -n "$TUNNEL_MSG" ]; then
    echo "1. 🌐 $TUNNEL_MSG"
    echo "2. ✅ Verify the backend is running: sudo systemctl status arca"
    echo "3. 📄 View live application logs: sudo journalctl -fu arca"
else
    echo "1. Verify the backend is running: sudo systemctl status arca"
    echo "2. View your live application logs: sudo journalctl -fu arca"
    echo "3. Restart the backend if you ever manually edit the .env file:"
    echo "   sudo systemctl restart arca"
fi
echo ""
echo "Arca is now installed and running locally on port 80!"
