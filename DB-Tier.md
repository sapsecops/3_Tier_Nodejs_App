## Launch EC2 "t2.micro" Instance and In Sg, Open port "27017" for MongoDB
# DB Tier
## Install MYSQL DB
```
sudo yum update -y
sudo wget https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
sudo dnf install mysql80-community-release-el9-1.noarch.rpm -y
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
sudo dnf install mysql-community-client -y
sudo dnf install mysql-community-server -y
sudo systemctl start mysqld
sudo systemctl enable mysqld
sudo systemctl status mysqld
```

## Setup MYSQL DB

#### Allow any Host connect to DB
```
sudo vi /etc/my.cnf
```
ADD these Under [mysqld]
```
bind-address = 0.0.0.0
```
Restart MYSQL DB
```
sudo systemctl restart mysqld
```

Get your temporary root Password
```
sudo grep 'temporary password' /var/log/mysqld.log
```
Setup your root Password
```
sudo mysql_secure_installation
```
Login to your MYSQL
```
mysql -u root -p
```
Test it is working or Not
```
SELECT VERSION();
```

## Create one Databse Admin User for our DB 
These user can login to DB to do Tasks and used 
```
CREATE USER '<user-name>'@'Host-IP' IDENTIFIED BY 'Password-HERE';
GRANT ALL PRIVILEGES ON <DB-Name>.* TO '<user-name>'@'Host-IP';
FLUSH PRIVILEGES;
```

```
CREATE USER 'dbadmin'@'%' IDENTIFIED BY 'Admin@123';
GRANT ALL PRIVILEGES ON *.* TO 'dbadmin'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```
HERE "." => All DB can Access By these User,
	 "%" => These User can allow from any Host-Machine
