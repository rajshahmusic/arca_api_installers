#!/data/data/com.termux/files/usr/bin/bash

# ==============================================================================
# ArcaPass - Termux (Android) Deployment Script
# ==============================================================================
# Run this script directly inside Termux on your Android phone!
# bash deployment/install_termux.sh
# ==============================================================================

# Enable strict error handling
set -e

error_handler() {
    echo ""
    echo "====================================================================="
    echo "❌ FATAL ERROR: Installation aborted!"
    echo "An unexpected error occurred at line \${BASH_LINENO[0]}."
    echo "Please review the log output above and try again."
    echo "====================================================================="
    exit 1
}
trap 'error_handler' ERR

echo "🚀 Starting Arca deployment for Termux (Android)..."

# Termux environment variables
INSTALL_DIR="$HOME/arca"

# 1. Update and install system dependencies
echo "📦 Installing Termux packages (Python, Nginx, SQLite, Git)..."
pkg update -y
pkg install -y python nginx sqlite git openssl openssl-tool wget rust binutils pkg-config libffi python-cryptography

# 2. Source Code Retrieval
echo "📁 Setting up codebase in $INSTALL_DIR..."
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
fi

read -p "Do you want to download the codebase directly from your GitHub repository? (y/n) [y]: " CLONE_GH
CLONE_GH=${CLONE_GH:-y}

if [ "$CLONE_GH" == "y" ]; then
    GH_URL="https://github.com/rajshahmusic/arca_api.git"
    
    echo "⬇️ Cloning repository..."
    git clone "$GH_URL" "$INSTALL_DIR/temp_clone"
    cp -a "$INSTALL_DIR/temp_clone/." "$INSTALL_DIR/"
    rm -rf "$INSTALL_DIR/temp_clone"
else
    echo "Moving local files to $INSTALL_DIR..."
    cp -a . "$INSTALL_DIR/"
fi

# Ensure the dist folder exists (warn if frontend hasn't been built)
if [ ! -d "$INSTALL_DIR/frontend/dist" ]; then
    echo "❌ FATAL ERROR: frontend/dist not found!"
    echo "   You should run 'npm run build' inside the frontend folder on your PC"
    echo "   and ensure the dist/ folder is committed to GitHub or transferred to the phone."
    echo "   The web interface cannot load without it."
    exit 1
fi

# 3. Setup Python Virtual Environment
echo "🐍 Setting up Python Virtual Environment..."
cd "$INSTALL_DIR"
# Termux struggles to build Rust-based packages from source.
# We will use the pre-compiled system versions and relax the pip requirements.
sed -i 's/^cryptography==.*/cryptography>=41.0.0/' requirements.txt
sed -i 's/^pydantic==.*/pydantic>=2.0.0/' requirements.txt
sed -i 's/^pydantic_core==.*/pydantic_core>=2.0.0/' requirements.txt

python -m venv --system-site-packages arcaenv
source arcaenv/bin/activate

# Provide fallbacks if it tries to build from source anyway
export ANDROID_API_LEVEL=24
export CARGO_BUILD_TARGET=aarch64-linux-android

echo "⬇️ Installing Python packages..."
pip install --upgrade pip
pip install -r requirements.txt --extra-index-url https://eutalix.github.io/android-pydantic-core/
deactivate

# 4. Configure Nginx Reverse Proxy (Port 8080)
echo "🌐 Configuring Nginx for Android (Port 8080)..."
NGINX_CONF="$PREFIX/etc/nginx/nginx.conf"

cat <<EOF > "$NGINX_CONF"
worker_processes  1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       8080;
        server_name  localhost;

        root $INSTALL_DIR/frontend/dist;
        index index.html;

        gzip on;
        gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

        location /api/ {
            proxy_pass http://127.0.0.1:8000/api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 5. Setup .env file via Interactive Wizard
while true; do
    echo "====================================================================="
    echo "⚙️  Network Configuration Wizard"
    echo "====================================================================="
    echo "Arca Passkeys require a Secure Context (HTTPS) to function correctly."
    echo "Please select how you will securely route traffic to this phone:"
    echo "  [1] Ngrok (Free Public URL - Recommended for external access)"
    echo "  [2] Tailscale (Use the Tailscale Android App from the Play Store)"
    echo "  [3] Local Network (e.g., localhost:8080)"
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
        echo "Because you are on Android, you must install the Tailscale App"
        echo "from the Google Play Store to use this option."
        echo ""
        read -p "Would you like to proceed with Tailscale? (y/n) [y] or type 'back' to return: " PROCEED
        if [ "$PROCEED" == "back" ] || [ "$PROCEED" == "n" ]; then
            echo ""
            continue
        fi
        
        read -p "Enter your exact Tailscale domain/IP (WITHOUT https:// or trailing slashes, e.g., 'arca.ts.net'): " RP_ID
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
    EXPECTED_ORIGIN="http://localhost:8080"
else
    EXPECTED_ORIGIN="https://$RP_ID"
fi

echo "📝 Generating .env configuration..."
SECRET=$(openssl rand -hex 32)

cat <<EOF > "$INSTALL_DIR/.env"
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

if [ "$ROUTE_OPT" == "1" ]; then
    echo "☁️ Installing Ngrok..."
    cd "$HOME"
    wget https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz -O ngrok.tgz
    tar -xvzf ngrok.tgz
    rm ngrok.tgz
    chmod +x "$HOME/ngrok"
    
    echo "🔑 Authenticating Ngrok..."
    "$HOME/ngrok" config add-authtoken "$NGROK_TOKEN"
    echo "✅ Ngrok installed and authenticated!"
fi

# 6. Auto-Updates (Cronjob)
echo "====================================================================="
echo "🔄 Auto-Updates"
echo "====================================================================="
read -p "Do you want Arca to automatically pull updates from GitHub every night at 3 AM? (y/n) [n]: " AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-n}

if [ "$AUTO_UPDATE" == "y" ]; then
    echo "📅 Installing cronie and setting up nightly cronjob..."
    pkg install -y cronie
    # Start cron daemon
    crond
    # Add to crontab
    (crontab -l 2>/dev/null; echo "0 3 * * * bash $INSTALL_DIR/deployment/backup_termux.sh > $INSTALL_DIR/backup.log 2>&1 && bash $INSTALL_DIR/deployment/update_termux.sh > $INSTALL_DIR/update.log 2>&1") | crontab -
    echo "✅ Auto-updates enabled!"

else
    echo "Auto-updates disabled. You can manually update anytime by running: bash $INSTALL_DIR/deployment/update_termux.sh"
fi

# 7. Setup Autostart (Termux:Boot)
echo "====================================================================="
echo "🚀 Autostart Configuration"
echo "====================================================================="
echo "Configuring Termux:Boot so Arca starts automatically if your phone reboots..."
mkdir -p "$HOME/.termux/boot"
cat <<EOF > "$HOME/.termux/boot/start-arca.sh"
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sshd
crond
bash $HOME/restart_arca.sh
EOF
chmod +x "$HOME/.termux/boot/start-arca.sh"
echo "✅ Autostart configured!"

# 8. Create Home Directory Shortcuts
echo "====================================================================="
echo "⚙️  Creating Shortcuts"
echo "====================================================================="
cp "$INSTALL_DIR/deployment/restart_termux.sh" "$HOME/restart_arca.sh"
chmod +x "$HOME/restart_arca.sh"

cp "$INSTALL_DIR/deployment/update_termux.sh" "$HOME/update_arca.sh"
chmod +x "$HOME/update_arca.sh"

cat <<EOF > "$HOME/logs_arca.sh"
#!/data/data/com.termux/files/usr/bin/bash
tail -f $INSTALL_DIR/uvicorn.log
EOF
chmod +x "$HOME/logs_arca.sh"

echo "✅ Copied scripts to ~/restart_arca.sh, ~/update_arca.sh, and ~/logs_arca.sh"

echo "====================================================================="
echo "✅ Arca Installation Complete (Termux)!"
echo "====================================================================="
echo ""
if [ "$ROUTE_OPT" == "2" ]; then
    echo "⚠️  Important: Open the Tailscale app on your phone and connect."
fi

echo ""
echo "Arca will be accessible locally at http://localhost:8080"
if [ "$ROUTE_OPT" == "1" ]; then
    echo "Arca will be accessible publicly at https://$RP_ID"
fi
echo ""
echo "🚀 Automatically starting Arca..."
bash "$HOME/restart_arca.sh"
