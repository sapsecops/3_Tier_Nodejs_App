#!/bin/bash

### === CONFIGURATION === ###
DB_HOST="<DB-PRIVATE-IP>"   # <-- UPDATE THIS
DB_USER="appuser"
DB_PASS="Aditya"
DB_NAME="crud_app"
JWT_SECRET="sapsecopsSuperSecretKey"

git_url="https://github.com/sapsecops/3_Tier_Nodejs_App.git"
APP_PATH="/home/ec2-user/"
APP_DIR="$APP_PATH/3_Tier_Nodejs_App"
Branch_Name="01-Local-setup"

echo "===== Updating OS ====="
sudo yum update -y

echo "===== Installing Node using NVM ====="
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.34.0/install.sh | bash
source ~/.nvm/nvm.sh
nvm install 16

echo "===== Node & NPM Version ====="
node -v
npm -v

echo "===== Installing Git ====="
sudo yum install git -y

echo "===== Cloning Application Repo ====="
git clone $git_url
cd $APP_DIR
git checkout $Branch_Name

echo "===== Setting Ownership ====="
sudo chown -R ec2-user:ec2-user $APP_DIR

cd api

echo "===== Installing MySQL Client ====="
sudo yum update -y
sudo wget https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
sudo dnf install mysql80-community-release-el9-1.noarch.rpm -y
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
sudo dnf install mysql-community-client -y

echo "===== Running initdb.sql ====="
mysql -h $DB_HOST -udbadmin -pAdmin@123 < initdb.sql

echo "===== Creating .env File ====="
cat <<EOF | sudo tee .env
DB_HOST=$DB_HOST
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASS
DB_NAME=$DB_NAME
JWT_SECRET=$JWT_SECRET
EOF

echo "===== Installing Node Dependencies ====="
npm install

echo "===== Installing PM2 (Production Process Manager) ====="
sudo npm install -g pm2

echo "===== Starting Backend with PM2 ====="
pm2 start app.js --name backend

echo "===== Saving PM2 Process ====="
pm2 save

