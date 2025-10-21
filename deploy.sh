#!/bin/bash
# ============================================
# Automated Deployment Script (HNG Stage 1)
# Author: Amos Agbetile
# Description: Fully automated Docker deployment with Nginx reverse proxy
# ============================================

set -eu  # Exit on error (-e), fail if variable undefined (-u)
trap 'echo "ERROR: Deployment failed at $(date)" | tee -a $LOG_FILE' ERR

# Log setup
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Deployment started at $(date)"

# ============================================
# STEP 1 — Collect user input
# ============================================
read -p "Enter Git repository URL: " REPO_URL
read -p "Enter your GitHub Personal Access Token (PAT): " PAT
read -p "Enter branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Remote SSH username: " SSH_USER
read -p "Remote server IP: " SERVER_IP
read -p "Path to SSH private key (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH
read -p "Enter application internal port (e.g., 5000): " APP_PORT

echo "All parameters captured successfully."

# ============================================
# STEP 2 — Clone or update repository
# ============================================
REPO_NAME=$(basename "$REPO_URL" .git)

if [ -d "$REPO_NAME" ]; then
  echo "Repository already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git pull origin "$BRANCH"
else
   echo "Cloning repository..."
  GIT_ASKPASS=$(mktemp)
  echo "echo $PAT" > "$GIT_ASKPASS"
  chmod +x "$GIT_ASKPASS"
  GIT_ASKPASS="$GIT_ASKPASS" git clone -b "$BRANCH" "https://$PAT@${REPO_URL#https://}" 
  cd "$REPO_NAME"
fi

# ============================================
# STEP 3 — Validate Dockerfile existence
# ============================================
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  echo "Docker configuration found."
else
  echo "No Dockerfile or docker-compose.yml found. Exiting."
  exit 1
fi

# ============================================
# STEP 4 — Test SSH Connection
# ============================================
echo "Testing SSH connection to $SERVER_IP..."
if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo ok" >/dev/null 2>&1; then
  echo "SSH connection successful."
else
  echo "SSH connection failed. Check credentials or key path."
  exit 1
fi

# ============================================
# STEP 5 — Prepare Remote Environment
# ============================================
echo "⚙️ Setting up environment on remote server..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -eu
  sudo yum update -y
  
# Add Docker repo (for CentOS/RHEL 9)
  sudo dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true

  sudo dnf -y install dnf-plugins-core
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Install Docker + Compose + Nginx
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nginx
    
  sudo systemctl enable docker nginx
  sudo systemctl start docker nginx
  sudo usermod -aG docker \$USER
EOF

# ============================================
# STEP 6 — Deploy Dockerized Application
# ============================================
echo "Transferring project files..."
scp -i "$SSH_KEY_PATH" -r . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/$REPO_NAME"

echo "Building and starting Docker container..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -eu
  cd /home/$SSH_USER/$REPO_NAME
  sudo docker stop myapp || true
  sudo docker rm myapp || true
  sudo docker build -t myapp .
  sudo docker run -d -p $APP_PORT:$APP_PORT --name myapp myapp
EOF

# ============================================
# STEP 7 — Configure Nginx Reverse Proxy
# ============================================
echo "Configuring Nginx as reverse proxy..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<EOF
  sudo bash -c 'cat > /etc/nginx/sites-available/myapp.conf <<NGINX
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX'
  sudo ln -sf /etc/nginx/sites-available/myapp.conf /etc/nginx/sites-enabled/
  sudo nginx -t
  sudo systemctl reload nginx
EOF

# ============================================
# STEP 8 — Validate Deployment
# ============================================
echo "Validating deployment..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash <<EOF
  sudo docker ps | grep myapp && echo "Docker container running."
  curl -I localhost | head -n 1
EOF

echo "Deployment complete! Access your app at http://$SERVER_IP"

