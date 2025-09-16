CREATE DATABASE IF NOT EXISTS crud_app;

CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'P@55Word';
GRANT ALL PRIVILEGES ON crud_app.* TO 'appuser'@'%';
FLUSH PRIVILEGES;

USE crud_app;

CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL UNIQUE,
  password VARCHAR(255) NOT NULL,
  role ENUM('admin', 'viewer') NOT NULL DEFAULT 'viewer',
  is_active TINYINT(1) DEFAULT 1,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert dummy data
INSERT INTO users (name, email, password, role, is_active)
VALUES
('Venkatesh', 'venkatesh@example.com', 'pass123', 'admin', 1),
('Chaitanya', 'chaitanya@example.com', 'pass123', 'viewer', 1),
('Padol', 'padol@example.com', 'pass123', 'viewer', 1),
('Ganesh', 'ganesh@example.com', 'pass123', 'viewer', 1),
('Pandu', 'pandu@example.com', 'pass123', 'viewer', 1);
