## Launch EC2 "t2.micro" Instance and In Sg, Open port "5000" for Python Application 
# Backend-Node.js Application server

## Install Node and NPM
```
sudo yum update -y
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.34.0/install.sh | bash
. ~/.nvm/nvm.sh
nvm install 16
```
### Check Node Version
```
node -v
npm -v
```
### Install Git
```
sudo yum install git -y
```
## Get the Code
```
git clone https://github.com/sapsecops/3_Tier_Nodejs_App.git
cd 3_Tier_Nodejs_App
git checkout 01-Local-setup
sudo chown -R ec2-user:ec2-user /home/ec2-user/3_Tier_Nodejs_App
```
```
cd api
```
## Setup your Application Database by executing "initdb.sql" script from Application-server

Step:1 ==> install "MYSQL-Client" for communicate with MYSQL Database
```
sudo yum update -y
sudo wget https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
sudo dnf install mysql80-community-release-el9-1.noarch.rpm -y
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
sudo dnf install mysql-community-client -y
```
Step:2 ==> Execute your "init.sql" script for your Application DB setup

```
mysql -h <DB-Prvate-IP> -udbadmin -pAdmin@123 < initdb.sql
```
## Add .env for DB Credentials 
```
sudo vim .env
```
```
DB_HOST=<DB-Private-IP>
DB_USER=appuser
DB_PASSWORD=Aditya
DB_NAME=crud_app
JWT_SECRET=sapsecopsSuperSecretKey
```

## Install Dependencies
```
npm install
```

## Start the App
```
npm start
```
HERE it is not recommend in Production, so we follow the HA in Production

Start Backend Application
```
npm install -g pm2
```
To run these Backend Application up and Running we use Pm2 service
```
pm2 start app.js --name backend
```
<img width="1089" height="110" alt="image" src="https://github.com/user-attachments/assets/4acd9488-9434-4dc3-86a1-c598bd6658c0" />

To list all pm2 Services
```
pm2 list
```
To stop these pm2 service
```
pm2 stop backend
```
<img width="1105" height="127" alt="image" src="https://github.com/user-attachments/assets/a584378a-fb91-4911-8112-51cf7e49ab0e" />

To delete these pm2 service
```
pm2 delete backend
```

